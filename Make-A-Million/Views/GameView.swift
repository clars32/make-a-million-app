//
//  GameView.swift
//  Make-A-Million
//

import SwiftUI

struct GameView: View {
    @StateObject private var session = GameSession()
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)
    @State private var showingSettings = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesTabletChrome: Bool { horizontalSizeClass == .regular }

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

            HStack(spacing: usesTabletChrome ? 12 : 8) {
                Button {
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(TableIconButtonStyle(tint: TableStyle.cardSelected,
                                                  size: usesTabletChrome ? 44 : 38))
                .accessibilityLabel("Settings")

                Button {
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    onExit()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(TablePillButtonStyle(tint: TableStyle.teamAmber,
                                                  emphasis: .tinted,
                                                  compact: !usesTabletChrome))
            }
            .font(usesTabletChrome ? TableTypography.display(.title3, weight: .semibold) : TableTypography.display(.body))
            .controlSize(usesTabletChrome ? .large : .regular)
            .padding(usesTabletChrome ? 24 : 16)
        }
        .sheet(isPresented: $showingSettings) {
            // Rules lock only while a hand is actually being played; display
            // toggles stay live. Between hands / at the start screen
            // (`running == false`) rules are editable and apply to the next deal.
            SettingsView(settings: .shared,
                         rulesLocked: session.running,
                         dealSeed: session.currentHandSeed ?? dealSeed) {
                showingSettings = false
            }
        }
        .onAppear { BackgroundMusicPlayer.shared.setGameActive(true) }
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

private struct BoardHeaderCenterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var cardNS
    @State private var discardSelection: Set<Card> = []
    @State private var selectedBidIndex: Int = 0
    @State private var bidHistoryExpanded: Bool = true
    @State private var dealAnimationTrigger: Int = -1
    @State private var lastDealAnimationToken: Int = -1
    @State private var showingDealAnimation: Bool = false
    @State private var selectedTrickHistorySeat: PlayerID? = nil
    @State private var boardHeaderCenterHeight: CGFloat = 0

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
                if showingDealAnimation {
                    if let table = tableView {
                        dealAnimationTable(
                            table: table,
                            decision: decisionView ?? table,
                            interactive: isInteractive)
                    } else {
                        EmptyView()
                    }
                } else if let snapshot = endOfHandSnapshot {
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
                    if v.phase == .bidding { selectedBidIndex = 0 }
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
            .onChange(of: settings.showFullTrickHistory) { _, enabled in
                if !enabled { selectedTrickHistorySeat = nil }
            }
            .onChange(of: dealAnimationToken(for: tableView)) { _, token in
                startDealAnimationIfNeeded(token)
            }
            .onAppear {
                startDealAnimationIfNeeded(dealAnimationToken(for: tableView))
            }

        }
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.2)
            Text("Waiting for the table…")
                .font(TableTypography.display(.callout))
                .foregroundStyle(.white.opacity(0.8))
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
                boardHeader(table, decision: decision, interactive: interactive)

                if showsBidHistoryStrip(table) {
                    bidHistoryStrip(table)
                }

                if table.phase == .misdealDecision {
                    misdealBanner(table, decision: decision, interactive: interactive)
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
                        hintText("Highlighted cards are legal.")
                    } else if !interactive {
                        hintText(caughtUp ? "Waiting for other players…" : "Watching play…")
                    }
                }

                handSection(table: table, decision: decision, interactive: interactive)
            }
            .padding(.horizontal, isTabletLayout ? 24 : 12)
            .padding(.top, isTabletLayout ? 94 : 64)   // clear the floating gear / Back buttons
            .padding(.bottom, isTabletLayout ? 10 : 6)

            if centerActionActive {
                actionPanel(decision)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, 70)   // bias up, clear of the hand
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

            trickHistoryOverlay(table)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.85), value: actionActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectedTrickHistorySeat)
    }

    private func dealAnimationTable(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        let actionActive = interactive && isActionPhase(decision.phase)
        let biddingActive = interactive && decision.phase == .bidding
        let centerActionActive = actionActive && !biddingActive
        return VStack(spacing: 8) {
            boardHeader(table, decision: decision, interactive: false)
                .hidden()

            if table.phase == .misdealDecision {
                misdealBanner(table, decision: decision, interactive: false)
                    .hidden()
            }

            Spacer(minLength: 0)

            boardArea(table,
                      showLiveCards: false,
                      showsIdleText: false,
                      dealAnimationTrigger: dealAnimationTrigger)
                .scaleEffect(centerActionActive ? 0.92 : 1.0, anchor: .top)

            Spacer(minLength: 0)

            footerStrip(table)
                .hidden()

            if biddingActive {
                biddingActionPanel(decision)
                    .padding(.horizontal, 4)
                    .hidden()
            } else if !actionActive {
                if interactive && decision.phase == .trickPlay {
                    hintText("Highlighted cards are legal.")
                        .hidden()
                } else if !interactive {
                    hintText(caughtUp ? "Waiting for other players…" : "Watching play…")
                        .hidden()
                }
            }

            handSection(table: table, decision: decision, interactive: interactive)
                .hidden()
        }
        .padding(.horizontal, isTabletLayout ? 24 : 12)
        .padding(.top, isTabletLayout ? 94 : 64)
        .padding(.bottom, isTabletLayout ? 10 : 6)
        .allowsHitTesting(false)
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
                Button {
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    toggleDiscardSelection(card)
                } label: {
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

    private func boardHeader(_ table: PlayerView,
                             decision: PlayerView,
                             interactive: Bool) -> some View {
        let status = phaseStatus(table: table,
                                 decision: decision,
                                 interactive: interactive)
        let scoreMinHeight = boardHeaderCenterHeight > 0 ? boardHeaderCenterHeight : nil
        return HStack(alignment: .top, spacing: isTabletLayout ? 14 : 6) {
            teamScorePill(team: 0, table, minHeight: scoreMinHeight)
            VStack(spacing: 6) {
                Text(table.phase.headline)
                    .font(TableTypography.display(isTabletLayout ? .title2 : .headline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                headerBadges(table)
                if let status {
                    phaseStatusBadge(status)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BoardHeaderCenterHeightKey.self,
                                           value: proxy.size.height)
                }
            }
            teamScorePill(team: 1, table, minHeight: scoreMinHeight)
        }
        .onPreferenceChange(BoardHeaderCenterHeightKey.self) { height in
            guard height > 0, abs(boardHeaderCenterHeight - height) > 0.5 else { return }
            boardHeaderCenterHeight = height
        }
    }

    private func phaseStatus(table: PlayerView,
                             decision: PlayerView,
                             interactive: Bool)
    -> (title: String, detail: String?, icon: String, tint: Color)? {
        if interactive {
            switch decision.phase {
            case .bidding:
                return ("Your bid", "Pick amount or pass", "hand.raised.fill", TableStyle.tableGold)
            case .namingTrump:
                return ("Your call", "Choose trump", "paintpalette.fill", TableStyle.cardSelected)
            case .widowDiscard:
                return ("Your discard", "\(discardSelection.count)/3 selected", "tray.and.arrow.down.fill", TableStyle.tableGold)
            case .trickPlay:
                return ("Your turn", "Play highlighted card", "rectangle.stack.fill", TableStyle.cardPlayable)
            case .misdealDecision:
                return ("Your vote", "Redeal or keep hand", "arrow.triangle.2.circlepath", TableStyle.teamAmber)
            case .handComplete:
                return nil
            }
        }

        guard isLivePhase(table.phase) else { return nil }
        return (caughtUp ? "Waiting on \(seatName(table.toAct))" : "Watching play",
                nil,
                "hourglass",
                TableStyle.passGray)
    }

    @ViewBuilder
    private func phaseStatusBadge(
        _ status: (title: String, detail: String?, icon: String, tint: Color)
    ) -> some View {
        if isTabletLayout {
            HStack(spacing: 7) {
                Image(systemName: status.icon)
                    .font(TableTypography.display(.caption, weight: .bold))
                Text(status.title)
                    .font(TableTypography.display(.callout, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                if let detail = status.detail {
                    Text(detail)
                        .font(TableTypography.display(.caption))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .layoutPriority(2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.tint.opacity(0.20)))
            .overlay(Capsule().stroke(status.tint.opacity(0.58), lineWidth: 1))
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: status.icon)
                    .font(TableTypography.display(.caption, weight: .bold))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.title)
                        .font(TableTypography.display(.caption, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    if let detail = status.detail {
                        Text(detail)
                            .font(TableTypography.display(.caption2))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.tint.opacity(0.20)))
            .overlay(Capsule().stroke(status.tint.opacity(0.58), lineWidth: 1))
            .accessibilityElement(children: .combine)
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
            HStack(spacing: isTabletLayout ? 10 : 6) {
                if let t = table.trump { trumpBadge(t) }
                if let bid = table.highBid, let bidder = table.highBidder {
                    bidBadge(bidder: bidder, amount: bid)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func teamScorePill(team: Int,
                               _ table: PlayerView,
                               minHeight: CGFloat? = nil) -> some View {
        let tint = TableStyle.teamTint(team)
        let isMine = Seats.team(of: table.me) == team
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        // "Show live scores" off: hide the running hand total (captured
        // tricks stay face-down at a real table); the settled match score
        // still shows.
        return VStack(alignment: .leading, spacing: isTabletLayout ? 4 : 2) {
            Text(team == 0 ? teamAName : teamBName)
                .font(TableTypography.display(isTabletLayout ? .callout : .caption2, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(settings.showLiveScores ? "$\(hand / 1000)k" : "$\(match / 1000)k")
                .font(TableTypography.money(isTabletLayout ? .title3 : .callout))
                .foregroundStyle(.white)
            if settings.showLiveScores {
                Text("$\(match / 1000)k")
                    .font(TableTypography.money(isTabletLayout ? .callout : .caption2, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, isTabletLayout ? 16 : 9)
        .padding(.vertical, isTabletLayout ? 12 : 7)
        .frame(width: isTabletLayout ? 142 : 88, alignment: .leading)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
                        .fill(tint.opacity(isMine ? 0.18 : 0.10))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
            .stroke(tint.opacity(isMine ? 0.82 : 0.42), lineWidth: isMine ? 2 : 1))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private func trumpBadge(_ color: CardColor) -> some View {
        let swatch = TableStyle.suitSwatch(color)
        return HStack(spacing: isTabletLayout ? 8 : 5) {
            Circle().fill(swatch)
                .frame(width: isTabletLayout ? 18 : 12,
                       height: isTabletLayout ? 18 : 12)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text(color.displayName)
                .font(TableTypography.display(isTabletLayout ? .headline : .caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, isTabletLayout ? 14 : 9)
        .padding(.vertical, isTabletLayout ? 7 : 4)
        .background(Capsule().fill(swatch.opacity(color == .black ? 0.34 : 0.22)))
        .overlay(Capsule().stroke(swatch.opacity(0.68), lineWidth: 1))
        .accessibilityLabel("Trump: \(color.displayName)")
    }

    private func bidBadge(bidder: PlayerID, amount: Int) -> some View {
        HStack(spacing: isTabletLayout ? 7 : 4) {
            Image(systemName: "crown.fill")
                .font(isTabletLayout ? .subheadline : .caption2)
                .foregroundStyle(TableStyle.tableGold)
            Text("\(seatShort(bidder)) $\(amount / 1000)k")
                .font(TableTypography.display(isTabletLayout ? .headline : .caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, isTabletLayout ? 14 : 9)
        .padding(.vertical, isTabletLayout ? 7 : 4)
        .background(Capsule().fill(TableStyle.tableGold.opacity(0.18)))
        .overlay(Capsule().stroke(TableStyle.tableGold.opacity(0.58), lineWidth: 1))
    }

    // MARK: Board (opponent seats + center trick)

    private func boardArea(_ table: PlayerView,
                           showLiveCards: Bool = true,
                           showsIdleText: Bool = true,
                           dealAnimationTrigger: Int? = nil) -> some View {
        let metrics = soloBoardMetrics
        return ZStack {
            ZStack {
                CenterTrickView(
                    currentTrick: showLiveCards ? table.currentTrick : nil,
                    completedTricks: showLiveCards ? table.completedTricks : [],
                    trump: table.trump,
                    viewer: table.me,
                    metrics: metrics,
                    seatName: seatName,
                    showsIdleText: showsIdleText,
                    showsAnimalCues: settings.animalAnimations,
                    cardNS: showLiveCards ? cardNS : nil)

                if let dealAnimationTrigger {
                    DealingAnimationOverlay(
                        trigger: dealAnimationTrigger,
                        cardWidth: isTabletLayout ? 96 : 68,
                        cardHeight: isTabletLayout ? 135 : 96,
                        spreadScale: isTabletLayout ? 0.66 : 0.60)
                    .frame(width: metrics.frame, height: metrics.frame)
                }
            }

            // All four seats are marked, relative to the local player: bottom
            // (you), left, top (partner), right — mirroring the tabletop board.
            seatChip(relativeSeat(2, from: table.me), table)
                .offset(seatChipOffset(direction: 2))
            seatChip(table.me, table)
                .offset(seatChipOffset(direction: 0))
            seatChip(relativeSeat(1, from: table.me), table)
                .offset(seatChipOffset(direction: 1))
            seatChip(relativeSeat(3, from: table.me), table)
                .offset(seatChipOffset(direction: 3))
        }
        .frame(maxWidth: .infinity)
        .frame(height: soloBoardHeight)
    }

    private func seatChipOffset(direction: Int) -> CGSize {
        let distance = soloBoardSeatDistance
        switch direction {
        case 0: return CGSize(width: 0, height: distance)
        case 1: return CGSize(width: -distance, height: 0)
        case 2: return CGSize(width: 0, height: -distance)
        case 3: return CGSize(width: distance, height: 0)
        default: return .zero
        }
    }

    private var isTabletLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var soloBoardMetrics: CenterTrickView.Metrics {
        isTabletLayout ? .tablet : .phone
    }

    private var soloBoardHeight: CGFloat {
        isTabletLayout ? 640 : 320
    }

    private var soloBoardSeatDistance: CGFloat {
        isTabletLayout ? 296 : 154
    }

    private var miniCardWidth: CGFloat {
        isTabletLayout ? 76 : 38
    }

    private var miniCardHeight: CGFloat {
        isTabletLayout ? 52 : 26
    }

    private var handCardWidth: CGFloat {
        isTabletLayout ? 112 : 60
    }

    private var handCardHeight: CGFloat {
        isTabletLayout ? 158 : 85
    }

    private var handSectionHeight: CGFloat {
        isTabletLayout ? 250 : 120
    }

    private var handRotationPad: CGFloat {
        isTabletLayout ? 240 : 80
    }

    private var handPreferredOverlap: CGFloat {
        isTabletLayout ? 52 : 30
    }

    private var handAnglePerCard: Double {
        isTabletLayout ? 2.6 : 3.5
    }

    private var handOuterDip: CGFloat {
        isTabletLayout ? 22 : 12
    }

    @ViewBuilder
    private func seatChip(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let chip = seatChipContent(seat, table)
        if settings.showFullTrickHistory {
            Button {
                toggleTrickHistorySeat(seat)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(seatName(seat)) trick history")
        } else {
            chip
        }
    }

    private func seatChipContent(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let selected = settings.showFullTrickHistory && selectedTrickHistorySeat == seat
        let tint = TableStyle.teamTint(Seats.team(of: seat))
        return VStack(spacing: isTabletLayout ? 4 : 2) {
            HStack(spacing: isTabletLayout ? 6 : 4) {
                if dealerSeat(table) == seat {
                    Text("D")
                        .font(TableTypography.display(isTabletLayout ? .callout : .caption2, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: isTabletLayout ? 24 : 16,
                               height: isTabletLayout ? 24 : 16)
                        .background(Circle().fill(.white.opacity(0.9)))
                }
                Text(seatName(seat))
                    .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .bold))
                    .foregroundStyle(.white).lineLimit(1)
            }
            seatSubtitle(seat, table)
        }
        .padding(.horizontal, isTabletLayout ? 20 : 12)
        .padding(.vertical, isTabletLayout ? 10 : 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(tint.opacity(toAct ? 0.20 : 0.11))
                }
        }
        .overlay(Capsule().stroke(selected ? TableStyle.tableGold : (toAct ? TableStyle.panelStrokeActive : tint.opacity(0.55)),
                                  lineWidth: selected ? (isTabletLayout ? 3 : 2.5) : (toAct ? (isTabletLayout ? 3 : 2.5) : 1.5)))
        .shadow(color: selected ? TableStyle.tableGold.opacity(0.45) : (toAct ? TableStyle.panelStrokeActive.opacity(0.48) : .black.opacity(0.25)),
                radius: selected || toAct ? (isTabletLayout ? 12 : 8) : 3, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: selected)
    }

    @ViewBuilder
    private func trickHistoryOverlay(_ table: PlayerView) -> some View {
        if settings.showFullTrickHistory, let seat = selectedTrickHistorySeat {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { dismissTrickHistory() }
                .transition(.opacity)

            TrickHistoryPanel(
                seat: seat,
                completedTricks: table.completedTricks,
                seatName: seatName,
                seatShort: seatShort,
                miniCardWidth: isTabletLayout ? 66 : 46,
                miniCardHeight: isTabletLayout ? 46 : 32,
                maxHeight: isTabletLayout ? 360 : 250,
                onClose: dismissTrickHistory)
            .padding(.horizontal, isTabletLayout ? 24 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, isTabletLayout ? 292 : 142)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    private func toggleTrickHistorySeat(_ seat: PlayerID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedTrickHistorySeat = selectedTrickHistorySeat == seat ? nil : seat
        }
    }

    private func dismissTrickHistory() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedTrickHistorySeat = nil
        }
    }

    @ViewBuilder
    private func seatSubtitle(_ seat: PlayerID, _ table: PlayerView) -> some View {
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidHistoryLabel(last.action))
                    .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white)
            } else {
                Text("…")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: isTabletLayout ? 5 : 3) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill")
                        .font(.system(size: isTabletLayout ? 12 : 8))
                        .foregroundStyle(TableStyle.tableGold)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Footer (widow + last trick)

    @ViewBuilder
    private func footerStrip(_ table: PlayerView) -> some View {
        let widow = settings.showWidow ? (table.widow ?? []) : []
        let showLast = settings.showLastTrick && table.lastTrick != nil
        // The discard announcement is public table talk even when the widow
        // panel is hidden (privately-held widow, or the display toggle off) —
        // it gets its own small panel in that case.
        let loneAnnouncement: DiscardAnnouncement? = {
            guard widow.isEmpty, let ann = table.discardAnnouncement,
                  ann.hasPublicContent else { return nil }
            return ann
        }()
        if !widow.isEmpty || showLast || loneAnnouncement != nil {
            HStack(alignment: .bottom, spacing: isTabletLayout ? 22 : 12) {
                if let ann = loneAnnouncement {
                    HStack(spacing: isTabletLayout ? 6 : 4) {
                        Text(ann.summaryText)
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                            MiniCardFace(card: entry.card,
                                         width: miniCardWidth * 0.8,
                                         height: miniCardHeight * 0.8)
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
                if !widow.isEmpty {
                    VStack(alignment: .leading, spacing: isTabletLayout ? 7 : 4) {
                        Text("Widow")
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: isTabletLayout ? 8 : 5) {
                            ForEach(keyedHand(widow), id: \.key) { entry in
                                MiniCardFace(card: entry.card,
                                             width: miniCardWidth,
                                             height: miniCardHeight)
                            }
                        }
                        // Public discard announcement: trump count spoken,
                        // money shown face-up. Stays visible all hand, like
                        // the widow itself.
                        if let ann = table.discardAnnouncement, ann.hasPublicContent {
                            HStack(spacing: isTabletLayout ? 6 : 4) {
                                Text(ann.summaryText)
                                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                                    .foregroundStyle(.white.opacity(0.7))
                                ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                                    MiniCardFace(card: entry.card,
                                                 width: miniCardWidth * 0.8,
                                                 height: miniCardHeight * 0.8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
                Spacer(minLength: isTabletLayout ? 16 : 8)
                if showLast, let last = table.lastTrick {
                    VStack(alignment: .trailing, spacing: isTabletLayout ? 7 : 4) {
                        Text("Last trick · \(seatShort(last.winner)) $\(last.value / 1000)k")
                            .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: isTabletLayout ? 8 : 5) {
                            ForEach(keyedPlays(last.plays), id: \.key) { entry in
                                MiniCardFace(card: entry.play.card,
                                             faded: entry.play.player != last.winner,
                                             width: miniCardWidth,
                                             height: miniCardHeight)
                            }
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isTabletLayout ? 8 : 4)
        }
    }

    private func hintText(_ s: String) -> some View {
        Text(s)
            .font(TableTypography.display(isTabletLayout ? .callout : .caption))
            .italic()
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Hand

    private func handSection(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        VStack(spacing: isTabletLayout ? 4 : 2) {
            Text("Your hand (\(table.myHand.count))")
                .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                .foregroundStyle(.white.opacity(0.6))
            FannedHand(cards: table.myHand,
                       cardWidth: handCardWidth,
                       rotationPad: handRotationPad,
                       preferredOverlap: handPreferredOverlap,
                       anglePerCard: handAnglePerCard,
                       outerDip: handOuterDip,
                       liftedCards: discardSelection) { card, n in
                handCard(card, decision: decision, interactive: interactive, totalCards: n)
            }
            .padding(.top, isTabletLayout ? 34 : 18)
            .padding(.bottom, isTabletLayout ? 48 : 30)
            .frame(height: handSectionHeight)
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

    private func startDealAnimationIfNeeded(_ token: Int) {
        guard token >= 0, token != lastDealAnimationToken else { return }
        lastDealAnimationToken = token
        showingDealAnimation = true
        dealAnimationTrigger = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            dealAnimationTrigger = token
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            if lastDealAnimationToken == token {
                showingDealAnimation = false
            }
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
        TableFeltBackground()
    }

    /// Misdeal notice. Automatic rule: a brief "redealing" banner. Agreement
    /// rule: when it is this player's turn to vote, the banner carries the
    /// Redeal / Keep buttons; otherwise it shows who the table is waiting on.
    private func misdealBanner(_ view: PlayerView, decision: PlayerView,
                               interactive: Bool) -> some View {
        let myMoney = view.myHand.reduce(0) { $0 + $1.moneyValue }
        let canVote = interactive
            && decision.phase == .misdealDecision
            && decision.legalMoves.contains(.declineMisdeal)
        return VStack(spacing: 10) {
            HStack(alignment: .top, spacing: isTabletLayout ? 14 : 10) {
                ZStack {
                    Circle()
                        .fill(TableStyle.teamAmber.opacity(0.24))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .headline, weight: .bold))
                        .foregroundStyle(TableStyle.teamAmber)
                }
                .frame(width: isTabletLayout ? 42 : 34,
                       height: isTabletLayout ? 42 : 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(canVote ? "Misdeal called — redeal?" : "Misdeal called")
                        .font(TableTypography.display(isTabletLayout ? .headline : .subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("A player has too little money in hand. Your hand: $\(myMoney / 1000)k in money cards.")
                        .font(TableTypography.display(isTabletLayout ? .callout : .caption))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
                if !canVote {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TableStyle.teamAmber)
                        .padding(.top, 6)
                }
            }
            if canVote {
                HStack(spacing: 10) {
                    Button("Redeal") {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(.callMisdeal)
                    }
                    .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                      compact: true))
                    Button("Keep this hand") {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(.declineMisdeal)
                    }
                    .buttonStyle(TablePillButtonStyle(tint: TableStyle.teamAmber,
                                                      emphasis: .tinted,
                                                      compact: true))
                }
                .font(TableTypography.display(.subheadline, weight: .semibold))
            }
        }
        .padding(.horizontal, isTabletLayout ? 18 : 14)
        .padding(.vertical, isTabletLayout ? 14 : 12)
        .frame(maxWidth: isTabletLayout ? 620 : .infinity)
        .background {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                        .fill(.black.opacity(0.24))
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(TableStyle.teamAmber)
                        .frame(width: isTabletLayout ? 7 : 5)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .stroke(TableStyle.teamAmber.opacity(0.82), lineWidth: 1.5)
        }
        .shadow(color: TableStyle.teamAmber.opacity(0.20), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }

    // MARK: Bid history strip (during bidding, and through the hand when
    // the Card display setting keeps it visible)

    private func showsBidHistoryStrip(_ table: PlayerView) -> Bool {
        guard !table.bidHistory.isEmpty else { return false }
        return table.phase == .bidding || settings.showBidHistoryDuringHand
    }

    private func bidHistoryStrip(_ table: PlayerView) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isTabletLayout ? 8 : 5) {
                Text("Bids")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(Array(table.bidHistory.enumerated()), id: \.offset) { _, record in
                    HStack(spacing: 4) {
                        Text(seatShort(record.player))
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(bidHistoryLabel(record.action))
                            .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, isTabletLayout ? 9 : 6)
                    .padding(.vertical, isTabletLayout ? 5 : 3)
                    .background(Capsule().fill(bidHistoryTint(record).opacity(0.16)))
                    .overlay(Capsule().stroke(bidHistoryTint(record).opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(.center)
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
        .frame(width: actionPanelContentWidth(for: view), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(14)
        .tablePanel(cornerRadius: 18, shadowOpacity: 0.34)
    }

    private func actionPanelContentWidth(for view: PlayerView) -> CGFloat? {
        switch view.phase {
        case .namingTrump:
            return trumpPanelContentWidth
        case .widowDiscard:
            return discardPanelContentWidth
        default:
            return nil
        }
    }

    private func biddingActionPanel(_ view: PlayerView) -> some View {
        biddingPanel(view)
            .padding(.vertical, isTabletLayout ? 6 : 5)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.26)
    }

    @ViewBuilder
    private func biddingPanel(_ view: PlayerView) -> some View {
        let passMove = view.legalMoves.first { $0.isPass }
        let bidMoves = view.legalMoves.filter { $0.bidAmount != nil }
        let bidAmounts = bidMoves.compactMap(\.bidAmount)
        let safeBidIndex = min(selectedBidIndex, max(0, bidMoves.count - 1))
        let bidSelection = Binding<Int>(
            get: { min(selectedBidIndex, max(0, bidMoves.count - 1)) },
            set: { selectedBidIndex = $0 }
        )

        HStack(spacing: isTabletLayout ? 12 : 8) {
            if !bidMoves.isEmpty {
                BidAmountWheel(
                    amounts: bidAmounts,
                    selection: bidSelection,
                    width: isTabletLayout ? 112 : 82,
                    height: isTabletLayout ? 76 : 62,
                    rowHeight: isTabletLayout ? 24 : 20,
                    textStyle: isTabletLayout ? .title3 : .callout)
            }

            HStack(spacing: isTabletLayout ? 10 : 8) {
                Button {
                    guard !bidMoves.isEmpty else { return }
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    submit(bidMoves[safeBidIndex])
                } label: {
                    Text("Bid")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: isTabletLayout ? 112 : 78,
                               height: isTabletLayout ? 44 : 36)
                        .background(Capsule(style: .continuous).fill(TableStyle.actionBlue))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(bidMoves.isEmpty)
                .opacity(bidMoves.isEmpty ? 0.45 : 1)

                Button {
                    guard let passMove else { return }
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    submit(passMove)
                } label: {
                    Text("Pass")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: isTabletLayout ? 112 : 78,
                               height: isTabletLayout ? 44 : 36)
                        .background(Capsule(style: .continuous).fill(TableStyle.passGray.opacity(0.82)))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(passMove == nil)
                .opacity(passMove == nil ? 0.45 : 1)
            }
        }
        .padding(.horizontal, isTabletLayout ? 12 : 10)
    }

    private func trumpNamingPanel(_ view: PlayerView) -> some View {
        // Build the four color buttons from CardColor directly, not from
        // move.label — the bid panel's label-munging produced "Bid Trump: Red",
        // which is what this panel is here to replace.
        let trumpMoves: [(CardColor, Move)] = view.legalMoves.compactMap { move in
            if case .nameTrump(let c) = move { return (c, move) }
            return nil
        }
        let buttonWidth = trumpButtonWidth
        let buttonHeight: CGFloat = isTabletLayout ? 52 : 48
        let gridSpacing = trumpGridSpacing
        let contentWidth = trumpPanelContentWidth
        let columns = [
            GridItem(.fixed(buttonWidth), spacing: gridSpacing),
            GridItem(.fixed(buttonWidth), spacing: gridSpacing)
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Choose trump. Discard comes next.")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: contentWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(trumpMoves, id: \.0) { color, move in
                    // `CardColor.black` maps to `Color.primary` in `swatch`, which
                    // inverts in dark mode and would render the Black trump button
                    // as white-on-white. The selector should always show the suit
                    // color faithfully, so override `.black` to a literal black.
                    let solidSwatch = TableStyle.suitSwatch(color)
                    Button {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(move)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(solidSwatch)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                            Text(color.displayName)
                                .font(TableTypography.display(.headline, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .frame(width: buttonWidth, height: buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(solidSwatch.opacity(color == .black ? 0.68 : 0.76))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(solidSwatch, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: contentWidth)
        }
    }

    private func widowDiscardPanel(_ view: PlayerView) -> some View {
        let count = discardSelection.count
        let ready = count == 3
        let legalMove = ready ? matchingWidowDiscardMove(selection: discardSelection, in: view) : nil
        let panelWidth = discardPanelContentWidth

        return VStack(alignment: .leading, spacing: 8) {
            Text(discardHelpText(for: view))
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: panelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if ready && legalMove == nil {
                Text("That discard isn't legal — discard your other colors first, then trump, and money only when nothing else is left.")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(TableStyle.teamAmber)
                    .frame(width: panelWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("\(count) of 3 selected")
                    .font(TableTypography.money(.callout, weight: .regular))
                    .foregroundStyle(.white)
                Spacer()
                Button("Discard selected") {
                    if let move = legalMove {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(move)
                        discardSelection = []
                    }
                }
                .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                  compact: true))
                .disabled(legalMove == nil)
                .opacity(legalMove == nil ? 0.50 : 1.0)
            }
            .frame(width: panelWidth)
        }
        .frame(width: panelWidth, alignment: .leading)
    }

    private var trumpButtonWidth: CGFloat {
        isTabletLayout ? 142 : 126
    }

    private var trumpGridSpacing: CGFloat {
        10
    }

    private var trumpPanelContentWidth: CGFloat {
        trumpButtonWidth * 2 + trumpGridSpacing
    }

    private var discardPanelContentWidth: CGFloat {
        isTabletLayout ? 330 : 286
    }
    
    private func discardHelpText(for view: PlayerView) -> String {
        if let trump = view.trump {
            return "Select 3 cards. Other colors go first; \(trump.displayName) trump and money unlock only when required."
        } else {
            return "Select 3 cards from your hand."
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
        // Mirror of GameState.isLegalWidowDiscard's tier order: plain cards
        // fill the discard first, then trump (announced by count), then
        // money (shown face-up). A protected card is only tappable when the
        // safer tiers combined can't fill the three slots. The engine's
        // legality check is the authority; this mirror keeps the UI from
        // offering taps the engine would reject.
        let plainPool = view.myHand.filter { candidate in
            guard !candidate.isSpecial, !candidate.isMoney else { return false }
            if let trump = view.trump {
                return candidate.effectiveColor(trump: trump) != trump
            }
            return true
        }
        if card.isMoney {
            let trumpPool = view.myHand.filter { candidate in
                guard let trump = view.trump else { return false }
                return !candidate.isSpecial && !candidate.isMoney
                    && candidate.effectiveColor(trump: trump) == trump
            }
            return plainPool.count + trumpPool.count < 3
        }
        if let trump = view.trump, card.effectiveColor(trump: trump) == trump {
            return plainPool.count < 3
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
                .font(TableTypography.display(.title2, weight: .bold)).foregroundStyle(.white)
            if let winner = s.matchWinner {
                Text("\(winner == 0 ? teamAName : teamBName) wins!")
                    .font(TableTypography.display(.headline, weight: .bold)).foregroundStyle(TableStyle.tableGold)
            }
            Text("\(teamAName): $\(a / 1000)k").foregroundStyle(.white)
            Text("\(teamBName): $\(b / 1000)k").foregroundStyle(.white.opacity(0.7))
            if !s.bidHistory.isEmpty {
                bidHistoryPanel(records: s.bidHistory, opener: s.opener)
            }
            HandRevealPanel(reveal: s.debugReveal)
            if let dealAnother {
                let label = (s.matchWinner == nil) ? "Next hand" : "Start new match"
                Button {
                    dealAnother()
                } label: {
                    Label(label, systemImage: s.matchWinner == nil
                          ? "arrow.right.circle.fill"
                          : "arrow.clockwise.circle.fill")
                }
                .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                  compact: true))
            }
        }
        .padding(20)
        .tablePanel(cornerRadius: 20, shadowOpacity: 0.30)
    }

    private func bidHistoryPanel(records: [BidRecord], opener: PlayerID) -> some View {
        DisclosureGroup(isExpanded: $bidHistoryExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Opener: \(seatName(opener))").font(TableTypography.display(.caption2, weight: .bold)).foregroundStyle(TableStyle.cardSelected)
                    Spacer()
                }
                if records.isEmpty {
                    Text("Waiting for \(seatName(opener)) to open").font(TableTypography.display(.caption2)).foregroundStyle(.tertiary)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                            let firstMention = !records[..<index].contains { $0.player == record.player }
                            HStack(spacing: 4) {
                                Text(seatShort(record.player)).font(TableTypography.display(.caption2)).foregroundStyle(.secondary)
                                if record.player == opener && firstMention {
                                    Text("opens").font(TableTypography.display(.caption2)).foregroundStyle(TableStyle.cardSelected)
                                }
                                Text(bidHistoryLabel(record.action)).font(TableTypography.money(.caption2))
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
        .font(TableTypography.display(.caption))
        .padding(10)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.16)
    }

    private func bidHistorySummary(records: [BidRecord], opener: PlayerID) -> some View {
        let winning = records.reversed().first { rec in
            if case .bid = rec.action { return true }; return false
        }
        return HStack(spacing: 8) {
            Text("Bid history").font(TableTypography.display(.caption)).foregroundStyle(.secondary)
            Spacer()
            if let w = winning, case .bid(let amount) = w.action {
                Text("\(seatShort(w.player)) $\(amount / 1000)k")
                    .font(TableTypography.money(.caption))
                    .foregroundStyle(TableStyle.tableGold)
            } else {
                Text("Opener: \(seatName(opener))").font(TableTypography.display(.caption2)).foregroundStyle(.tertiary)
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
        case .pass: return TableStyle.passGray
        case .bid: return TableStyle.tableGold
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
                 highlighted: highlighted,
                 width: handCardWidth,
                 height: handCardHeight,
                 dense: totalCards > 12)
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
