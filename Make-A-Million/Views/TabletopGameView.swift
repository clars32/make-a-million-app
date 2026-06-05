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
    @State private var showingSettings = false

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

            DealingAnimationOverlay(
                trigger: dealAnimationToken(for: tableView),
                cardWidth: 86,
                cardHeight: 121,
                spreadScale: 0.92)
            .padding(.top, 84)
            .padding(.bottom, 118)
            .zIndex(2)

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
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                headerBadges(table)
            }
            Spacer(minLength: 8)
            teamScoreCard(team: 1, table)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func headerBadges(_ table: PlayerView) -> some View {
        if table.trump == nil, let bid = table.highBid, let bidder = table.highBidder {
            HStack {
                Spacer(minLength: 0)
                bidBadge(bidder: bidder, amount: bid)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 10) {
                if let t = table.trump { trumpBadge(t) }
                if let bid = table.highBid, let bidder = table.highBidder {
                    bidBadge(bidder: bidder, amount: bid)
                }
            }
        }
    }

    private func teamScoreCard(team: Int, _ table: PlayerView) -> some View {
        let tint = TableStyle.teamTint(team)
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        let progress = min(1.0, Double(match) / 1_000_000.0)
        return VStack(alignment: .leading, spacing: 3) {
            Text(teamName(team)).font(TableTypography.display(.subheadline, weight: .bold)).foregroundStyle(tint)
            Text("Hand $\(hand / 1000)k")
                .font(TableTypography.money(.title2))
                .foregroundStyle(.white)
            Text("Match $\(match / 1000)k / $1M")
                .font(TableTypography.money(.caption, weight: .regular)).foregroundStyle(.white.opacity(0.7))
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
        .tablePanel(cornerRadius: 14, shadowOpacity: 0.20)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.50), lineWidth: 1))
    }

    // MARK: Seat markers

    private func seatMarker(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let tint = TableStyle.teamTint(Seats.team(of: seat))
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                if dealerSeat(table) == seat {
                    Text("D")
                        .font(TableTypography.display(.caption, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.9)))
                        .help("Dealer")
                }
                Text(seatName(seat))
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
            }
            seatSubtitle(seat, table)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(tint.opacity(toAct ? 0.20 : 0.11))
                }
        }
        .overlay(
            Capsule().stroke(toAct ? TableStyle.panelStrokeActive : tint.opacity(0.55),
                             lineWidth: toAct ? 3 : 1.5))
        .shadow(color: toAct ? TableStyle.panelStrokeActive.opacity(0.48) : .black.opacity(0.25),
                radius: toAct ? 10 : 4, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
    }

    @ViewBuilder
    private func seatSubtitle(_ seat: PlayerID, _ table: PlayerView) -> some View {
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed").font(TableTypography.display(.caption)).foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidLabel(last.action))
                    .font(TableTypography.money(.caption))
                    .foregroundStyle(.white)
            } else {
                Text("…").font(TableTypography.display(.caption)).foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: 4) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill").font(TableTypography.display(.caption2)).foregroundStyle(TableStyle.tableGold)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(TableTypography.display(.caption)).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Center trick

    /// Tabletop is an absolute board: seat 0 sits at the bottom, so we pass
    /// `viewer: PlayerID(0)`. The geometry and animations live in the shared
    /// CenterTrickView (also used by the phone-sized GameBody board).
    private func trickCenter(_ table: PlayerView) -> some View {
        CenterTrickView(
            currentTrick: table.currentTrick,
            completedTricks: table.completedTricks,
            trump: table.trump,
            viewer: PlayerID(0),
            metrics: .tabletop,
            seatName: seatName)
    }

    // MARK: Footer (last trick / widow)

    @ViewBuilder
    private func footerStrip(_ table: PlayerView) -> some View {
        HStack(spacing: 20) {
            if let widow = table.widow, !widow.isEmpty {
                HStack(spacing: 8) {
                    Text("Widow").font(TableTypography.display(.headline, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    ForEach(keyedHand(widow), id: \.key) { entry in
                        CardFace(card: entry.card, width: 64, height: 90)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .tablePanel(cornerRadius: 14, shadowOpacity: 0.14)
            }
            Spacer()
            if settings.showLastTrick, let last = table.lastTrick {
                HStack(spacing: 8) {
                    Text("Last trick").font(TableTypography.display(.headline, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    ForEach(keyedPlays(last.plays), id: \.key) { entry in
                        CardFace(card: entry.play.card, faded: entry.play.player != last.winner,
                                 width: 64, height: 90)
                    }
                    Text("· \(seatShort(last.winner)) $\(last.value / 1000)k")
                        .font(TableTypography.money(.headline))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .tablePanel(cornerRadius: 14, shadowOpacity: 0.14)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 108)
    }

    // MARK: - Chrome

    private var feltBackground: some View {
        TableFeltBackground()
    }

    private var topBar: some View {
        HStack {
            Text("Tabletop")
                .font(TableTypography.display(.headline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .font(TableTypography.display(.subheadline, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(TableStyle.cardSelected)
            .accessibilityLabel("Settings")
            Button("End Match") { netSession.stop(); onExit() }
                .font(TableTypography.display(.subheadline, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(TableStyle.teamAmber)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.4)
            Text("Waiting for hand to start…")
                .font(TableTypography.display(.title3)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func bidBadge(bidder: PlayerID, amount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill").font(TableTypography.display(.subheadline)).foregroundStyle(TableStyle.tableGold)
            Text("\(seatName(bidder)) · $\(amount / 1000)k")
                .font(TableTypography.display(.headline, weight: .bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(TableStyle.tableGold.opacity(0.18)))
        .overlay(Capsule().stroke(TableStyle.tableGold.opacity(0.58), lineWidth: 1))
    }

    private func trumpBadge(_ color: CardColor) -> some View {
        let swatch = TableStyle.suitSwatch(color)
        return HStack(spacing: 8) {
            Circle().fill(swatch).frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text("Trump: \(color.displayName)")
                .font(TableTypography.display(.headline, weight: .bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(swatch.opacity(color == .black ? 0.34 : 0.22)))
        .overlay(Capsule().stroke(swatch.opacity(0.68), lineWidth: 1))
    }

    private func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        VStack(spacing: 16) {
            Text(s.matchWinner != nil ? "Match Complete!" : "Hand Complete")
                .font(TableTypography.display(.largeTitle, weight: .bold)).foregroundStyle(.white)
            if let winner = s.matchWinner {
                Text(teamName(winner) + " wins!")
                    .font(TableTypography.display(.title2)).foregroundStyle(TableStyle.tableGold)
            }
            if let bid = s.bidAmount, let bidder = s.bidder {
                let pts = s.biddingTeamPoints ?? 0
                let made = pts >= bid
                VStack(spacing: 4) {
                    Text("\(seatName(bidder)) bid $\(bid / 1000)k")
                        .font(TableTypography.display(.title3)).foregroundStyle(.white)
                    Text(made ? "Made it — took $\(pts / 1000)k"
                              : "Set — took only $\(pts / 1000)k")
                        .font(TableTypography.display(.headline, weight: .bold))
                        .foregroundStyle(made ? TableStyle.cardPlayable : TableStyle.teamAmber)
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 28) {
                VStack { Text(teamName(0)).font(TableTypography.display(.caption)).foregroundStyle(TableStyle.teamTint(0))
                    Text("$\(s.matchScore[0, default: 0] / 1000)k").font(TableTypography.money(.title3)).foregroundStyle(.white) }
                VStack { Text(teamName(1)).font(TableTypography.display(.caption)).foregroundStyle(TableStyle.teamTint(1))
                    Text("$\(s.matchScore[1, default: 0] / 1000)k").font(TableTypography.money(.title3)).foregroundStyle(.white) }
            }

            if s.matchWinner == nil {
                Button { netSession.startNextHand() } label: {
                    Label("Next Hand", systemImage: "arrow.right.circle.fill")
                        .font(TableTypography.display(.title3, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(TableStyle.actionBlue)
                .padding(.top, 8)
            } else {
                Button { netSession.start(dealSeed: .random(in: .min ... .max)) } label: {
                    Label("New Match", systemImage: "arrow.clockwise.circle.fill")
                        .font(TableTypography.display(.title3, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(TableStyle.actionBlue)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .tablePanel(cornerRadius: 24, shadowOpacity: 0.30)
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
                    .font(.system(size: 64)).foregroundStyle(TableStyle.teamAmber)
                Text("Table Paused").font(TableTypography.display(.largeTitle, weight: .bold)).foregroundStyle(.white)
                Text("\(droppedName) lost connection. Wait for them to rejoin, replace them with a bot, or end the match.")
                    .font(TableTypography.display(.title3)).foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center).frame(maxWidth: 480)

                HStack(spacing: 16) {
                    Button {
                        netSession.resumeWithBot()
                    } label: {
                        Label("Continue with Bot", systemImage: "cpu").font(TableTypography.display(.headline, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TableStyle.actionBlue)

                    Button(role: .destructive) {
                        netSession.stop(); onExit()
                    } label: {
                        Label("End Match", systemImage: "xmark.circle").font(TableTypography.display(.headline, weight: .bold))
                    }
                    .buttonStyle(.bordered).tint(TableStyle.teamAmber)
                }
                .padding(.top, 8)
            }
            .padding(40)
            .tablePanel(cornerRadius: 24, shadowOpacity: 0.34)
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
