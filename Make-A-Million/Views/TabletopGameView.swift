//
//  TabletopGameView.swift
//  Make-a-Million
//
//  The shared board (iPad on the table). Lays the four players out at the
//  cardinal edges — South(0) bottom, West(1) left, North(2) top, East(3) right
//  — with the trick forming in the center, each card nudged toward the side of
//  the player who played it. All public reminders (scores, trump, high bid,
//  whose turn) live here so the phones can stay hand-only.
//
//  The center placement is also the anchor for the Phase 3 fly-in / sweep
//  animations.
//

import SwiftUI

struct TabletopGameView: View {

    @ObservedObject var netSession: NetSession
    @ObservedObject var gameSession: GameSession
    @EnvironmentObject private var settings: GameSettings
    let onExit: () -> Void

    @State private var lastView: PlayerView? = nil
    @State private var sweep: SweepState? = nil
    @State private var showingSettings = false

    /// A just-completed trick animating out toward its winner.
    private struct SweepState: Equatable {
        let index: Int
        let plays: [PlayedCard]
        let winner: PlayerID
        var arrived: Bool
    }

    // Tabletop card size (was a hard-to-read 110pt).
    private let trickCardW: CGFloat = 82
    private let trickCardH: CGFloat = 115
    private let centerSpread: CGFloat = 104  // how far each card sits from center

    private var tableView: PlayerView? { gameSession.displayView ?? lastView }

    private var displayTick: Int {
        guard let d = gameSession.displayView else { return -1 }
        return GameBody.animationToken(d)
    }

    private var endOfHandSnapshot: HandCompleteSnapshot? {
        guard let s = gameSession.finished else { return nil }
        let projection = s.view(for: PlayerID(0))
        let biddingTeam = s.highBidder.map { Seats.team(of: $0) }
        let biddingPoints = biddingTeam.map { projection.liveHandScore[$0, default: 0] }
        return HandCompleteSnapshot(
            matchScore: s.matchScore,
            matchWinner: s.matchWinner,
            bidHistory: s.bidHistory,
            opener: Seats.next(s.dealer),
            debugReveal: s.debugReveal(),
            bidAmount: s.highBid,
            bidder: s.highBidder,
            biddingTeamPoints: biddingPoints)
    }

    var body: some View {
        ZStack {
            feltBackground

            VStack(spacing: 0) {
                topBar
                Group {
                    if let snapshot = endOfHandSnapshot {
                        handCompleteView(snapshot)
                    } else if let table = tableView {
                        boardView(table)
                    } else {
                        waitingView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case .paused(let reason) = netSession.phase {
                pausedOverlay(reason: reason)
            }
        }
        .onChange(of: displayTick) { _, _ in
            guard let d = tableView else { return }
            DispatchQueue.main.async { lastView = d }
        }
        .sheet(isPresented: $showingSettings) {
            // Rules lock while a hand is being played; display toggles stay live.
            SettingsView(settings: .shared,
                         rulesLocked: netSession.phase == .running) {
                showingSettings = false
            }
        }
    }

    // MARK: - Board

    private func boardView(_ table: PlayerView) -> some View {
        VStack(spacing: 10) {
            headerStrip(table)

            ZStack {
                // North (top) and South (bottom)
                VStack {
                    seatMarker(PlayerID(2), table)
                    Spacer(minLength: 0)
                    seatMarker(PlayerID(0), table)
                }
                // West (left) and East (right)
                HStack {
                    seatMarker(PlayerID(1), table)
                    Spacer(minLength: 0)
                    seatMarker(PlayerID(3), table)
                }
                trickCenter(table)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 6)

            footerStrip(table)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    // MARK: Header (scores + phase + trump)

    private func headerStrip(_ table: PlayerView) -> some View {
        HStack(alignment: .top, spacing: 12) {
            teamScoreCard(team: 0, table)
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                Text(table.phase.headline)
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    if let t = table.trump { trumpBadge(t) }
                    if let bid = table.highBid, let bidder = table.highBidder {
                        bidBadge(bidder: bidder, amount: bid)
                    }
                }
            }
            Spacer(minLength: 8)
            teamScoreCard(team: 1, table)
        }
        .padding(.horizontal, 8)
    }

    private func teamScoreCard(team: Int, _ table: PlayerView) -> some View {
        let tint = team == 0 ? Color.cyan : Color.orange
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        let progress = min(1.0, Double(match) / 1_000_000.0)
        return VStack(alignment: .leading, spacing: 3) {
            Text(teamName(team)).font(.subheadline.bold()).foregroundStyle(tint)
            Text("Hand $\(hand / 1000)k")
                .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(.white)
            Text("Match $\(match / 1000)k / $1M")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(tint).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 180)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.5), lineWidth: 1))
    }

    // MARK: Seat markers

    private func seatMarker(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let tint = Seats.team(of: seat) == 0 ? Color.cyan : Color.orange
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                if dealerSeat(table) == seat {
                    Text("D")
                        .font(.caption.bold()).foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.9)))
                        .help("Dealer")
                }
                Text(seatName(seat))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.white)
            }
            seatSubtitle(seat, table)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(toAct ? Color.yellow : tint.opacity(0.55),
                             lineWidth: toAct ? 3 : 1.5))
        .shadow(color: toAct ? Color.yellow.opacity(0.5) : .black.opacity(0.25),
                radius: toAct ? 10 : 4, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
    }

    @ViewBuilder
    private func seatSubtitle(_ seat: PlayerID, _ table: PlayerView) -> some View {
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed").font(.caption).foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidLabel(last.action))
                    .font(.system(.caption, design: .rounded).bold().monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Text("…").font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: 4) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Center trick

    private func trickCenter(_ table: PlayerView) -> some View {
        let plays = table.currentTrick?.plays ?? []
        let idle = plays.isEmpty && sweep == nil
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 300, height: 300)

            // Led-suit reminder at dead center (cards rest out toward the edges).
            if let trump = table.trump,
               let led = table.currentTrick?.ledColor(trump: trump),
               !plays.isEmpty {
                VStack(spacing: 3) {
                    Circle().fill(colorSwatch(led)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    Text("Led").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }

            // In-progress trick — each card flies in from its player's side.
            ForEach(keyedPlays(plays), id: \.key) { entry in
                trickCard(entry.play)
                    .offset(centerOffset(for: entry.play.player))
                    .transition(flyIn(for: entry.play.player))
            }

            // Just-completed trick sweeping out to the winner.
            if let s = sweep {
                ForEach(keyedPlays(s.plays), id: \.key) { entry in
                    trickCard(entry.play)
                        .offset(s.arrived ? sweptOffset(for: s.winner)
                                          : centerOffset(for: entry.play.player))
                        .opacity(s.arrived ? 0 : 1)
                }
            }

            if idle {
                if let last = table.lastTrick {
                    Text("\(seatName(last.winner)) won $\(last.value / 1000)k")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("Waiting for the lead…")
                        .font(.title3).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 380, height: 380)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: plays.count)
        .onChange(of: table.completedTricks.count) { _, count in
            guard count > 0, let last = table.lastTrick else { sweep = nil; return }
            startSweep(last, index: count)
        }
    }

    private func trickCard(_ play: PlayedCard) -> some View {
        CardFace(card: play.card, width: trickCardW, height: trickCardH)
            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
    }

    /// Animate the four just-played cards toward the winner, then clear.
    private func startSweep(_ last: CompletedTrickInfo, index: Int) {
        sweep = SweepState(index: index, plays: last.plays, winner: last.winner, arrived: false)
        withAnimation(.easeIn(duration: 0.55)) {
            sweep?.arrived = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if sweep?.index == index { sweep = nil }
        }
    }

    /// Where a seat's card rests relative to center (toward that player's edge).
    private func centerOffset(for seat: PlayerID) -> CGSize {
        switch seat.raw {
        case 0: return CGSize(width: 0, height: centerSpread)   // South
        case 1: return CGSize(width: -centerSpread, height: 0)  // West
        case 2: return CGSize(width: 0, height: -centerSpread)  // North
        case 3: return CGSize(width: centerSpread, height: 0)   // East
        default: return .zero
        }
    }

    /// Off-table position toward a seat — used as both the fly-in start and the
    /// sweep-out destination.
    private func sweptOffset(for seat: PlayerID) -> CGSize {
        let c = centerOffset(for: seat)
        return CGSize(width: c.width * 2.8, height: c.height * 2.8)
    }

    /// Insertion transition: slide in from the player's edge; instant removal
    /// (the sweep overlay handles the visible exit).
    private func flyIn(for seat: PlayerID) -> AnyTransition {
        let c = centerOffset(for: seat)
        let delta = CGSize(width: c.width * 1.8, height: c.height * 1.8)
        return .asymmetric(
            insertion: .offset(delta).combined(with: .opacity),
            removal: .identity)
    }

    // MARK: Footer (last trick / widow)

    @ViewBuilder
    private func footerStrip(_ table: PlayerView) -> some View {
        HStack(spacing: 20) {
            if let widow = table.widow, !widow.isEmpty {
                HStack(spacing: 8) {
                    Text("Widow").font(.headline).foregroundStyle(.white.opacity(0.7))
                    ForEach(keyedHand(widow), id: \.key) { entry in
                        CardFace(card: entry.card, width: 50, height: 70)
                    }
                }
            }
            Spacer()
            if settings.showLastTrick, let last = table.lastTrick {
                HStack(spacing: 8) {
                    Text("Last trick").font(.headline).foregroundStyle(.white.opacity(0.7))
                    ForEach(keyedPlays(last.plays), id: \.key) { entry in
                        CardFace(card: entry.play.card, faded: entry.play.player != last.winner,
                                 width: 50, height: 70)
                    }
                    Text("· \(seatShort(last.winner)) $\(last.value / 1000)k")
                        .font(.headline.monospacedDigit().bold())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
    }

    // MARK: - Chrome

    private var feltBackground: some View {
        LinearGradient(colors: [Color(red: 0.06, green: 0.30, blue: 0.18),
                                Color(red: 0.03, green: 0.17, blue: 0.11)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Text("Tabletop")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .accessibilityLabel("Settings")
            Button("End Match") { netSession.stop(); onExit() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.4)
            Text("Waiting for hand to start…")
                .font(.title3).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func bidBadge(bidder: PlayerID, amount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill").font(.subheadline).foregroundStyle(.yellow)
            Text("\(seatName(bidder)) · $\(amount / 1000)k")
                .font(.headline.weight(.bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(Color.yellow.opacity(0.18)))
        .overlay(Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1))
    }

    private func trumpBadge(_ color: CardColor) -> some View {
        let swatch: Color = (color == .black) ? .black : color.swatch
        return HStack(spacing: 8) {
            Circle().fill(swatch).frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text("Trump: \(color.displayName)")
                .font(.headline.weight(.bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(swatch.opacity(0.3)))
        .overlay(Capsule().stroke(swatch.opacity(0.8), lineWidth: 1))
    }

    private func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        VStack(spacing: 16) {
            Text(s.matchWinner != nil ? "Match Complete!" : "Hand Complete")
                .font(.largeTitle).bold().foregroundStyle(.white)
            if let winner = s.matchWinner {
                Text(teamName(winner) + " wins!")
                    .font(.title2).foregroundStyle(.green)
            }
            if let bid = s.bidAmount, let bidder = s.bidder {
                let pts = s.biddingTeamPoints ?? 0
                let made = pts >= bid
                VStack(spacing: 4) {
                    Text("\(seatName(bidder)) bid $\(bid / 1000)k")
                        .font(.title3).foregroundStyle(.white)
                    Text(made ? "Made it — took $\(pts / 1000)k"
                              : "Set — took only $\(pts / 1000)k")
                        .font(.headline.bold())
                        .foregroundStyle(made ? .green : .red)
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 28) {
                VStack { Text(teamName(0)).font(.caption).foregroundStyle(.cyan)
                    Text("$\(s.matchScore[0, default: 0] / 1000)k").font(.title3.bold().monospacedDigit()).foregroundStyle(.white) }
                VStack { Text(teamName(1)).font(.caption).foregroundStyle(.orange)
                    Text("$\(s.matchScore[1, default: 0] / 1000)k").font(.title3.bold().monospacedDigit()).foregroundStyle(.white) }
            }

            if s.matchWinner == nil {
                Button { netSession.startNextHand() } label: {
                    Label("Next Hand", systemImage: "arrow.right.circle.fill")
                        .font(.title3.bold())
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            } else {
                Button { netSession.start(dealSeed: .random(in: .min ... .max)) } label: {
                    Label("New Match", systemImage: "arrow.clockwise.circle.fill")
                        .font(.title3.bold())
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .padding(40)
    }

    private func pausedOverlay(reason: PauseReason) -> some View {
        let droppedName: String = {
            if case .playerDisconnected(_, let name) = reason { return name }
            return "A player"
        }()
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 64)).foregroundStyle(.orange)
                Text("Table Paused").font(.largeTitle).bold()
                Text("\(droppedName) lost connection. Wait for them to rejoin, replace them with a bot, or end the match.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 480)

                HStack(spacing: 16) {
                    Button {
                        netSession.resumeWithBot()
                    } label: {
                        Label("Continue with Bot", systemImage: "cpu").font(.headline)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        netSession.stop(); onExit()
                    } label: {
                        Label("End Match", systemImage: "xmark.circle").font(.headline)
                    }
                    .buttonStyle(.bordered).tint(.red)
                }
                .padding(.top, 8)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func isLivePhase(_ p: Phase) -> Bool {
        switch p {
        case .bidding, .namingTrump, .widowDiscard, .trickPlay: return true
        default: return false
        }
    }

    /// The dealer sits one seat right of the opener (opener leads the bidding).
    private func dealerSeat(_ table: PlayerView) -> PlayerID {
        PlayerID((table.opener.raw + Seats.count - 1) % Seats.count)
    }

    private func colorSwatch(_ color: CardColor) -> Color {
        color == .black ? .black : color.swatch
    }

    private func teamName(_ team: Int) -> String {
        let seats = team == 0 ? [0, 2] : [1, 3]
        return "\(seatName(PlayerID(seats[0]))) + \(seatName(PlayerID(seats[1])))"
    }

    private func seatName(_ p: PlayerID) -> String {
        let names = netSession.seats.map(\.name)
        guard p.raw < names.count else { return "Seat \(p.raw)" }
        return names[p.raw]
    }

    private func seatShort(_ p: PlayerID) -> String {
        String(seatName(p).prefix(3)).uppercased()
    }

    private func bidLabel(_ action: BidAction) -> String {
        switch action {
        case .pass: return "Pass"
        case .bid(let amount): return "$\(amount / 1000)k"
        }
    }
}
