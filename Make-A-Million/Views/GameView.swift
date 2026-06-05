//
//  GameView.swift
//  Make-A-Million
//

import SwiftUI

struct GameView: View {
    @StateObject private var session = GameSession()
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)
    @State private var showingSettings = false

    /// Return to the home screen. Owned here (rather than in AppRoot's overlay)
    /// so this view can host the in-game settings entry alongside it and gate
    /// rule edits on `session.running`.
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SoloGameBody(session: session,
                         human: session.human,
                         dealSeed: $dealSeed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings")

                Button("Back", action: onExit)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .sheet(isPresented: $showingSettings) {
            // Rules lock only while a hand is actually being played; display
            // toggles stay live. Between hands / at the start screen
            // (`running == false`) rules are editable and apply to the next deal.
            SettingsView(settings: .shared,
                         rulesLocked: session.running,
                         dealSeed: dealSeed) {
                showingSettings = false
            }
        }
    }
}

// MARK: - Solo wrapper

private struct SoloGameBody: View {
    @ObservedObject var session: GameSession
    @ObservedObject var human: HumanAgent
    @Binding var dealSeed: UInt64

    @State private var lastView: PlayerView? = nil

    private var tableView: PlayerView? {
        session.displayView ?? human.pending ?? lastView
    }
    private var decisionView: PlayerView? {
        human.pending ?? session.displayView ?? lastView
    }
    private var isInteractive: Bool { human.pending != nil }

    private var pendingTick: Int {
        guard let p = human.pending else { return -1 }
        return GameBody.animationToken(p)
    }
    private var displayTick: Int {
        guard let d = session.displayView else { return -1 }
        return GameBody.animationToken(d)
    }

    private var endOfHandSnapshot: HandCompleteSnapshot? {
        guard let s = session.finished else { return nil }
        return HandCompleteSnapshot(
            matchScore: s.matchScore,
            matchWinner: s.matchWinner,
            bidHistory: s.bidHistory,
            opener: Seats.next(s.dealer),
            debugReveal: s.debugReveal())
    }

    var body: some View {
        GameBody(
            tableView: tableView,
            decisionView: decisionView ?? tableView,
            isInteractive: isInteractive,
            caughtUp: session.caughtUp,
            endOfHandSnapshot: endOfHandSnapshot,
            pendingTick: pendingTick,
            displayTick: displayTick,
            seatNames: ["You", "West", "North", "East"],
            submit: { move in human.submit(move) },
            dealAnother: {
                // Mid-match: continue the same game; the score and dealer
                // carry forward. Only after a team has won the match do we
                // wipe everything and start fresh.
                if let final = session.finished, final.matchWinner != nil {
                    dealSeed = .random(in: .min ... .max)
                    session.reset()
                    lastView = nil
                    session.startNewMatch(dealSeed: dealSeed)
                } else {
                    session.startNextHand()
                }
            },
            onCaptureLastView: { lastView = $0 })
        .onAppear {
            guard tableView == nil, session.finished == nil, !session.running else { return }
            session.startNewMatch(dealSeed: dealSeed)
        }
    }
}

// MARK: - Shared body

struct GameBody: View {

    let tableView: PlayerView?
    let decisionView: PlayerView?
    let isInteractive: Bool
    let caughtUp: Bool
    let endOfHandSnapshot: HandCompleteSnapshot?
    let pendingTick: Int
    let displayTick: Int
    
    // NEW: Dynamic Names
    let seatNames: [String]

    let submit: (Move) -> Void
    let dealAnother: (() -> Void)?
    let onCaptureLastView: ((PlayerView) -> Void)?

    @EnvironmentObject private var settings: GameSettings
    @Namespace private var cardNS
    @State private var discardSelection: Set<Card> = []
    @State private var selectedBidIndex: Int = 0
    @State private var bidHistoryExpanded: Bool = true

    private var teamAName: String {
        guard seatNames.count == 4 else { return "Team A" }
        return "\(seatNames[0]) + \(seatNames[2])"
    }
    
    private var teamBName: String {
        guard seatNames.count == 4 else { return "Team B" }
        return "\(seatNames[1]) + \(seatNames[3])"
    }

    var body: some View {
        ZStack {
            feltBackground

            Group {
                if let snapshot = endOfHandSnapshot {
                    handCompleteView(snapshot).padding()
                } else if let table = tableView {
                    activeView(
                        table: table,
                        decision: decisionView ?? table,
                        interactive: isInteractive)
                } else {
                    waitingView.padding()
                }
            }
            .onChange(of: pendingTick) { _, _ in
                guard let v = decisionView, isInteractive else { return }
                // Defer the captures off this frame: a burst of frames can
                // tick more than once per update, and writing @State inline
                // here cascades into SwiftUI's "multiple updates per frame".
                DispatchQueue.main.async {
                    onCaptureLastView?(v)
                    if v.phase != .widowDiscard { discardSelection = [] }
                }
            }
            .onChange(of: displayTick) { _, _ in
                guard let d = tableView else { return }
                DispatchQueue.main.async { onCaptureLastView?(d) }
            }
            .onChange(of: tableView?.phase) { _, newPhase in
                guard let newPhase else { return }
                bidHistoryExpanded = (newPhase == .bidding)
            }
        }
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.2)
            Text("Waiting for the table…")
                .font(.callout).foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: Active hand

    /// The phone "mini tabletop": scores + phase up top, the four-direction
    /// trick board in the middle (the local player at the bottom edge), the
    /// fanned hand below. Bidding controls sit just above the hand so the
    /// seat chips still show the other bids; trump/discard still float over
    /// the empty center.
    private func activeView(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        let actionActive = interactive && isActionPhase(decision.phase)
        let biddingActive = interactive && decision.phase == .bidding
        let centerActionActive = actionActive && !biddingActive
        return ZStack {
            VStack(spacing: 8) {
                boardHeader(table)

                if table.phase == .misdealDecision {
                    misdealBanner(table)
                }

                Spacer(minLength: 0)

                boardArea(table)
                    .scaleEffect(centerActionActive ? 0.92 : 1.0, anchor: .top)

                Spacer(minLength: 0)

                footerStrip(table)

                if biddingActive {
                    biddingActionPanel(decision)
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !actionActive {
                    if interactive && decision.phase == .trickPlay {
                        hintText("Tap a card in your hand to play it.")
                    } else if !interactive {
                        hintText(caughtUp ? "Waiting for other players…" : "Watching play…")
                    }
                }

                handSection(table: table, decision: decision, interactive: interactive)
            }
            .padding(.horizontal, 12)
            .padding(.top, 64)   // clear the floating gear / Back buttons
            .padding(.bottom, 6)

            if centerActionActive {
                actionPanel(decision)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, 70)   // bias up, clear of the hand
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.85), value: actionActive)
    }

    @ViewBuilder
    private func handCard(_ card: Card, decision: PlayerView, interactive: Bool, totalCards: Int) -> some View {
        let playable = isPlayable(card, in: decision)
        let discardSelectable = isDiscardSelectable(card, in: decision)
        let selected = discardSelection.contains(card)

        Group {
            if interactive && decision.phase == .trickPlay && playable {
                Button { submit(.play(card)) } label: {
                    cardChip(card, faded: false, selected: false, highlighted: true, totalCards: totalCards)
                }
                .buttonStyle(.plain)
            } else if interactive && decision.phase == .widowDiscard && discardSelectable {
                Button { toggleDiscardSelection(card) } label: {
                    cardChip(card, faded: false, selected: selected, highlighted: true, totalCards: totalCards)
                }
                .buttonStyle(.plain)
            } else {
                // No fade for non-discardable cards — the green border on
                // legal ones is enough to convey legality, same affordance
                // as during trick play.
                cardChip(card, faded: false, selected: selected, totalCards: totalCards)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: Score bar

    // MARK: Board header (scores + phase + trump / high bid)

    private func boardHeader(_ table: PlayerView) -> some View {
        HStack(alignment: .top, spacing: 6) {
            teamScorePill(team: 0, table)
            VStack(spacing: 6) {
                Text(table.phase.headline)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                headerBadges(table)
            }
            .frame(maxWidth: .infinity)
            teamScorePill(team: 1, table)
        }
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
            HStack(spacing: 6) {
                if let t = table.trump { trumpBadge(t) }
                if let bid = table.highBid, let bidder = table.highBidder {
                    bidBadge(bidder: bidder, amount: bid)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func teamScorePill(team: Int, _ table: PlayerView) -> some View {
        let tint = team == 0 ? Color.cyan : Color.orange
        let isMine = Seats.team(of: table.me) == team
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        return VStack(alignment: .leading, spacing: 2) {
            Text(team == 0 ? teamAName : teamBName)
                .font(.caption2.bold()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("$\(hand / 1000)k")
                .font(.system(.callout, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(.white)
            Text("$\(match / 1000)k")
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(width: 88, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(tint.opacity(isMine ? 0.9 : 0.4), lineWidth: isMine ? 2 : 1))
    }

    private func trumpBadge(_ color: CardColor) -> some View {
        let swatch: Color = (color == .black) ? .black : color.swatch
        return HStack(spacing: 5) {
            Circle().fill(swatch).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text(color.displayName)
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(swatch.opacity(0.3)))
        .overlay(Capsule().stroke(swatch.opacity(0.8), lineWidth: 1))
        .accessibilityLabel("Trump: \(color.displayName)")
    }

    private func bidBadge(bidder: PlayerID, amount: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow)
            Text("\(seatShort(bidder)) $\(amount / 1000)k")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.yellow.opacity(0.18)))
        .overlay(Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1))
    }

    // MARK: Board (opponent seats + center trick)

    private func boardArea(_ table: PlayerView) -> some View {
        ZStack {
            CenterTrickView(
                currentTrick: table.currentTrick,
                completedTricks: table.completedTricks,
                trump: table.trump,
                viewer: table.me,
                metrics: .phone,
                seatName: seatName,
                cardNS: cardNS)

            // All four seats are marked, relative to the local player: bottom
            // (you), left, top (partner), right — mirroring the tabletop board.
            VStack {
                seatChip(relativeSeat(2, from: table.me), table)
                    .offset(y: -35)
                Spacer()
                seatChip(table.me, table)
                    .offset(y: 35)
            }
            HStack {
                seatChip(relativeSeat(1, from: table.me), table)
                Spacer()
                seatChip(relativeSeat(3, from: table.me), table)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 264)
    }

    private func seatChip(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let tint = Seats.team(of: seat) == 0 ? Color.cyan : Color.orange
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                if dealerSeat(table) == seat {
                    Text("D").font(.caption2.bold()).foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.white.opacity(0.9)))
                }
                Text(seatName(seat))
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundStyle(.white).lineLimit(1)
            }
            seatSubtitle(seat, table)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(toAct ? Color.yellow : tint.opacity(0.55),
                                  lineWidth: toAct ? 2.5 : 1.5))
        .shadow(color: toAct ? Color.yellow.opacity(0.5) : .black.opacity(0.25),
                radius: toAct ? 8 : 3, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
    }

    @ViewBuilder
    private func seatSubtitle(_ seat: PlayerID, _ table: PlayerView) -> some View {
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed").font(.caption2).foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidHistoryLabel(last.action))
                    .font(.system(.caption2, design: .rounded).bold().monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Text("…").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: 3) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Footer (widow + last trick)

    @ViewBuilder
    private func footerStrip(_ table: PlayerView) -> some View {
        let widow = table.widow ?? []
        let showLast = settings.showLastTrick && table.lastTrick != nil
        if !widow.isEmpty || showLast {
            HStack(alignment: .bottom, spacing: 12) {
                if !widow.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Widow").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: 5) {
                            ForEach(keyedHand(widow), id: \.key) { entry in
                                MiniCardFace(card: entry.card)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                if showLast, let last = table.lastTrick {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Last trick · \(seatShort(last.winner)) $\(last.value / 1000)k")
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: 5) {
                            ForEach(keyedPlays(last.plays), id: \.key) { entry in
                                MiniCardFace(card: entry.play.card,
                                             faded: entry.play.player != last.winner)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
    }

    private func hintText(_ s: String) -> some View {
        Text(s).font(.caption).italic().foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Hand

    private func handSection(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        VStack(spacing: 2) {
            Text("Your hand (\(table.myHand.count))")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
            FannedHand(cards: table.myHand, liftedCards: discardSelection) { card, n in
                handCard(card, decision: decision, interactive: interactive, totalCards: n)
            }
            .padding(.top, 18)
            .padding(.bottom, 30)
            .frame(height: 120)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Board helpers

    private func isActionPhase(_ p: Phase) -> Bool {
        switch p {
        case .bidding, .namingTrump, .widowDiscard: return true
        default: return false
        }
    }

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

    /// The seat `dir` clockwise steps from `viewer` (1 left, 2 across, 3 right).
    private func relativeSeat(_ dir: Int, from viewer: PlayerID) -> PlayerID {
        PlayerID((viewer.raw + dir) % Seats.count)
    }

    private var feltBackground: some View {
        LinearGradient(colors: [Color(red: 0.06, green: 0.30, blue: 0.18),
                                Color(red: 0.03, green: 0.17, blue: 0.11)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private func misdealBanner(_ view: PlayerView) -> some View {
        let myMoney = view.myHand.reduce(0) { $0 + $1.moneyValue }
        return HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Misdeal — redealing").font(.subheadline).bold()
                Text("A player has too little money in hand. Your hand: $\(myMoney / 1000)k in money cards.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ProgressView().controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.5), lineWidth: 1))
    }

    // MARK: Action panel (bid / name trump / discard)

    /// Floats over the empty center during trump naming / widow discard.
    /// Bidding uses `biddingActionPanel` instead so the bid context remains
    /// visible around the table.
    @ViewBuilder
    private func actionPanel(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch view.phase {
            case .widowDiscard: widowDiscardPanel(view)
            case .namingTrump:  trumpNamingPanel(view)
            default:            EmptyView()
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }

    private func biddingActionPanel(_ view: PlayerView) -> some View {
        biddingPanel(view)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    @ViewBuilder
    private func biddingPanel(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let passMove = view.legalMoves.first { $0.isPass }
                let bidMoves = view.legalMoves.filter { $0.bidAmount != nil }
                let safeBidIndex = min(selectedBidIndex, max(0, bidMoves.count - 1))

                VStack(spacing: 14) {
                    if !bidMoves.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(bidMoves.enumerated()), id: \.offset) { index, move in
                                        let isSelected = index == safeBidIndex
                                        Button {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                selectedBidIndex = index
                                                proxy.scrollTo(index, anchor: .center)
                                            }
                                        } label: {
                                            Text(move.label.replacingOccurrences(of: "Bid ", with: ""))
                                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                                .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                                                .padding(.horizontal, 16)
                                                .frame(height: 44)
                                                .background {
                                                    Capsule(style: .continuous).fill(isSelected ? Color.blue : Color.white.opacity(0.15))
                                                }
                                                .scaleEffect(isSelected ? 1.05 : 0.95)
                                        }
                                        .buttonStyle(.plain)
                                        .id(index)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }
                            .frame(height: 58)
                        }
                    }

                    HStack(spacing: 10) {
                        if let passMove {
                            Button { submit(passMove) } label: {
                                Text("Pass")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 90, height: 42)
                                    .background(Capsule(style: .continuous).fill(.gray.opacity(0.75)))
                            }
                            .buttonStyle(.plain)
                        }
                        if !bidMoves.isEmpty {
                            Button { submit(bidMoves[safeBidIndex]) } label: {
                                Text("Bid \(bidMoves[safeBidIndex].label.replacingOccurrences(of: "Bid ", with: ""))")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(Capsule(style: .continuous).fill(Color.blue))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.horizontal)
        }
    }

    private func trumpNamingPanel(_ view: PlayerView) -> some View {
        // Build the four color buttons from CardColor directly, not from
        // move.label — the bid panel's label-munging produced "Bid Trump: Red",
        // which is what this panel is here to replace.
        let trumpMoves: [(CardColor, Move)] = view.legalMoves.compactMap { move in
            if case .nameTrump(let c) = move { return (c, move) }
            return nil
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pick the trump color for this hand. You'll discard three after.")
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(trumpMoves, id: \.0) { color, move in
                    // `CardColor.black` maps to `Color.primary` in `swatch`, which
                    // inverts in dark mode and would render the Black trump button
                    // as white-on-white. The selector should always show the suit
                    // color faithfully, so override `.black` to a literal black.
                    let solidSwatch: Color = (color == .black) ? .black : color.swatch
                    Button { submit(move) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(solidSwatch)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                            Text(color.displayName)
                                .font(.system(.headline, design: .rounded).weight(.bold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(solidSwatch.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(solidSwatch, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func widowDiscardPanel(_ view: PlayerView) -> some View {
        let count = discardSelection.count
        let ready = count == 3
        let legalMove = ready ? matchingWidowDiscardMove(selection: discardSelection, in: view) : nil

        return VStack(alignment: .leading, spacing: 8) {
            Text(discardHelpText(for: view))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            if ready && legalMove == nil {
                Text("That discard isn't legal — you can only discard money cards when you have no other choice.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text("\(count) of 3 selected")
                    .font(.system(.callout, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                Spacer()
                Button("Discard selected") {
                    if let move = legalMove { submit(move); discardSelection = [] }
                }
                .buttonStyle(.borderedProminent)
                .disabled(legalMove == nil)
            }
        }
    }
    
    private func discardHelpText(for view: PlayerView) -> String {
        if let trump = view.trump {
            return "Tap three cards in your hand to discard. Tiger, Bull, Bear, and \(trump.displayName) (trump) cards cannot be discarded."
        } else {
            return "Tap three cards in your hand to discard. Tiger, Bull, and Bear cannot be discarded."
        }
    }

    private func matchingWidowDiscardMove(selection: Set<Card>, in view: PlayerView) -> Move? {
        view.legalMoves.first { move in
            guard case .discardWidow(let cards) = move else { return false }
            return Set(cards) == selection
        }
    }

    private func isDiscardSelectable(_ card: Card, in view: PlayerView) -> Bool {
        guard view.phase == .widowDiscard else { return false }
        if card.isSpecial { return false }
        if let trump = view.trump, card.effectiveColor(trump: trump) == trump {
            // Trump is protected, except when the hand simply doesn't have
            // three non-special non-trump cards to fill the discard. The
            // engine's legality check is the authority; this mirror keeps
            // the UI from offering taps the engine would reject.
            let safePool = view.myHand.filter {
                !$0.isSpecial && $0.effectiveColor(trump: trump) != trump
            }
            return safePool.count < 3
        }
        if card.isMoney {
            let safeNonMoney = view.myHand.filter { candidate in
                guard !candidate.isSpecial, !candidate.isMoney else { return false }
                if let trump = view.trump {
                    return candidate.effectiveColor(trump: trump) != trump
                }
                return true
            }
            return safeNonMoney.count < 3
        }
        return true
    }

    private func toggleDiscardSelection(_ card: Card) {
        if discardSelection.contains(card) {
            discardSelection.remove(card)
        } else if discardSelection.count < 3 {
            discardSelection.insert(card)
        }
    }

    // MARK: Hand complete

    private func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        let a = s.matchScore[0, default: 0]
        let b = s.matchScore[1, default: 0]
        let matchOver = s.matchWinner != nil
        return VStack(spacing: 14) {
            Text(matchOver ? "Match complete" : "Hand complete")
                .font(.title2).bold().foregroundStyle(.white)
            if let winner = s.matchWinner {
                Text("\(winner == 0 ? teamAName : teamBName) wins!")
                    .font(.headline).foregroundStyle(.green)
            }
            Text("\(teamAName): $\(a / 1000)k").foregroundStyle(.white)
            Text("\(teamBName): $\(b / 1000)k").foregroundStyle(.white.opacity(0.7))
            if !s.bidHistory.isEmpty {
                bidHistoryPanel(records: s.bidHistory, opener: s.opener)
            }
            HandRevealPanel(reveal: s.debugReveal)
            if let dealAnother {
                let label = (s.matchWinner == nil) ? "Next hand" : "Start new match"
                Button(label, action: dealAnother).buttonStyle(.borderedProminent)
            }
        }
    }

    private func bidHistoryPanel(records: [BidRecord], opener: PlayerID) -> some View {
        DisclosureGroup(isExpanded: $bidHistoryExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Opener: \(seatName(opener))").font(.caption2).bold().foregroundStyle(.blue)
                    Spacer()
                }
                if records.isEmpty {
                    Text("Waiting for \(seatName(opener)) to open").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                            let firstMention = !records[..<index].contains { $0.player == record.player }
                            HStack(spacing: 4) {
                                Text(seatShort(record.player)).font(.caption2).foregroundStyle(.secondary)
                                if record.player == opener && firstMention {
                                    Text("opens").font(.caption2).foregroundStyle(.blue)
                                }
                                Text(bidHistoryLabel(record.action)).font(.caption2).bold().monospacedDigit()
                            }
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(bidHistoryTint(record).opacity(0.14)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(bidHistoryTint(record).opacity(0.45), lineWidth: 1))
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            bidHistorySummary(records: records, opener: opener)
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bidHistorySummary(records: [BidRecord], opener: PlayerID) -> some View {
        let winning = records.reversed().first { rec in
            if case .bid = rec.action { return true }; return false
        }
        return HStack(spacing: 8) {
            Text("Bid history").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let w = winning, case .bid(let amount) = w.action {
                Text("\(seatShort(w.player)) $\(amount / 1000)k")
                    .font(.system(.caption, design: .rounded).bold().monospacedDigit())
                    .foregroundStyle(.blue)
            } else {
                Text("Opener: \(seatName(opener))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Helpers - Dynamic Seat Naming

    private func seatName(_ p: PlayerID) -> String {
        guard p.raw < seatNames.count else { return "Seat \(p.raw)" }
        return seatNames[p.raw]
    }
    
    private func seatShort(_ p: PlayerID) -> String {
        guard p.raw < seatNames.count else { return "S\(p.raw)" }
        let name = seatNames[p.raw]
        // If it's the local player, keep it clean
        if name == "You" || name.contains("(You)") { return "You" }
        return String(name.prefix(3)).uppercased()
    }

    private func isPlayable(_ card: Card, in view: PlayerView) -> Bool {
        view.legalMoves.contains {
            if case .play(let c) = $0 { return c == card }; return false
        }
    }

    private func bidHistoryLabel(_ action: BidAction) -> String {
        switch action {
        case .pass: return "Pass"
        case .bid(let amount): return "$\(amount / 1000)k"
        }
    }

    private func bidHistoryTint(_ record: BidRecord) -> Color {
        switch record.action {
        case .pass: return .secondary
        case .bid: return .blue
        }
    }

    static func animationToken(_ v: PlayerView) -> Int {
        var token = v.myHand.count &* 1000
        token &+= (v.currentTrick?.plays.count ?? 0) &* 13
        token &+= v.completedTricks.count &* 100
        token &+= v.bidHistory.count &* 7
        return token
    }

    private func cardChip(_ card: Card, faded: Bool, selected: Bool = false, highlighted: Bool = false, totalCards: Int = 1) -> some View {
        CardFace(card: card, faded: faded, selected: selected,
                 highlighted: highlighted, dense: totalCards > 12)
    }
}

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
