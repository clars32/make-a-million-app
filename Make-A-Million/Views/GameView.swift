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

    /// When true, resume the saved solo match on appear instead of dealing a
    /// fresh one. Set by the menu's "Continue" entry; defaults to a new game.
    var resume: Bool = false

    /// Return to the home screen. Owned here (rather than in AppRoot's overlay)
    /// so this view can host the in-game settings entry alongside it and gate
    /// rule edits on `session.running`.
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SoloGameBody(session: session,
                         human: session.human,
                         dealSeed: $dealSeed,
                         resume: resume)
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
        .onAppear {
            #if canImport(UIKit)
            OrientationLock.shared.lock(.allButUpsideDown)
            #endif
            BackgroundMusicPlayer.shared.setGameActive(true)
        }
    }
}

// MARK: - Solo wrapper

private struct SoloGameBody: View {
    @ObservedObject var session: GameSession
    @ObservedObject var human: HumanAgent
    @Binding var dealSeed: UInt64
    var resume: Bool = false

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
        return HandCompleteSnapshot(final: s)
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
            onCaptureLastView: { lastView = $0 },
            allowsPhoneLandscapeLayout: true)
        .onAppear {
            guard tableView == nil, session.finished == nil, !session.running else { return }
            if resume, let saved = SoloGameStore.shared.saved {
                session.resume(from: saved)
            } else {
                session.startNewMatch(dealSeed: dealSeed)
            }
        }
    }
}

// Internal (not file-private): referenced from the GameBody board extension.
struct BoardHeaderCenterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GameBodyLayout: Equatable {
    enum Mode: Equatable {
        case phonePortrait
        case phoneLandscape
        case tablet
    }

    let mode: Mode
    let viewport: CGSize

    static func resolve(
        size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        allowsPhoneLandscape: Bool
    ) -> GameBodyLayout {
        let hasUsableSize = size.width > 0 && size.height > 0
        let isLandscapePhone = allowsPhoneLandscape
            && hasUsableSize
            && horizontalSizeClass != .regular
            && size.width > size.height
            && size.height <= 520

        if isLandscapePhone {
            return GameBodyLayout(mode: .phoneLandscape, viewport: size)
        }
        if horizontalSizeClass == .regular {
            return GameBodyLayout(mode: .tablet, viewport: size)
        }
        return GameBodyLayout(mode: .phonePortrait, viewport: size)
    }

    var isTablet: Bool { mode == .tablet }
    var isPhoneLandscape: Bool { mode == .phoneLandscape }

    var compactTextStyle: Font.TextStyle {
        isPhoneLandscape ? .caption2 : .caption
    }

    var contentHorizontalPadding: CGFloat {
        switch mode {
        case .tablet: return 24
        case .phoneLandscape: return viewport.width < 700 ? 8 : 10
        case .phonePortrait: return 12
        }
    }

    var contentTopPadding: CGFloat {
        switch mode {
        case .tablet: return 94
        case .phoneLandscape: return 8
        case .phonePortrait: return 64
        }
    }

    var contentBottomPadding: CGFloat {
        switch mode {
        case .tablet: return 10
        case .phoneLandscape: return 6
        case .phonePortrait: return 6
        }
    }

    var contentHeight: CGFloat {
        max(0, viewport.height - contentTopPadding - contentBottomPadding)
    }

    var stackSpacing: CGFloat {
        switch mode {
        case .tablet: return 8
        case .phoneLandscape: return 5
        case .phonePortrait: return 8
        }
    }

    var landscapeColumnSpacing: CGFloat { viewport.width < 700 ? 8 : 10 }

    var landscapeUsableWidth: CGFloat {
        max(0, viewport.width - contentHorizontalPadding * 2 - landscapeColumnSpacing)
    }

    var landscapeBoardColumnWidth: CGFloat {
        guard isPhoneLandscape else { return 0 }
        let preferred = landscapeUsableWidth * (viewport.width < 700 ? 0.42 : 0.40)
        let minimum: CGFloat = viewport.width < 620 ? 242 : (viewport.width < 700 ? 260 : 330)
        let maximum = min(viewport.width < 700 ? 310 : 360, landscapeUsableWidth - 320)
        return min(max(preferred, minimum), max(minimum, maximum))
    }

    var landscapeInfoColumnWidth: CGFloat {
        guard isPhoneLandscape else { return 0 }
        return max(260, landscapeUsableWidth - landscapeBoardColumnWidth)
    }

    var landscapeControlTopGap: CGFloat {
        guard isPhoneLandscape else { return 0 }
        return min(88, max(56, contentHeight * 0.18))
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
    var allowsPhoneLandscapeLayout: Bool = false

    @EnvironmentObject var settings: GameSettings
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Namespace var cardNS
    @State var discardSelection: Set<Card> = []
    @State var selectedBidIndex: Int = 0
    @State var dealAnimationTrigger: Int = -1
    @State var lastDealAnimationToken: Int = -1
    @State var showingDealAnimation: Bool = false
    @State var selectedTrickHistorySeat: PlayerID? = nil
    @State var boardHeaderCenterHeight: CGFloat = 0
    /// The seat the turn-highlight is drawn on. Tracks `table.toAct`, but during
    /// bidding it trails by a beat so a player's bid amount lands before the
    /// highlight hops to the next seat (the round is easier to follow that way).
    @State var displayedActiveSeat: PlayerID? = nil
    @State private var activeSeatToken: Int = 0

    var teamAName: String {
        guard seatNames.count == 4 else { return "Team A" }
        return "\(seatNames[0]) + \(seatNames[2])"
    }
    
    var teamBName: String {
        guard seatNames.count == 4 else { return "Team B" }
        return "\(seatNames[1]) + \(seatNames[3])"
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = GameBodyLayout.resolve(
                size: proxy.size,
                horizontalSizeClass: horizontalSizeClass,
                allowsPhoneLandscape: allowsPhoneLandscapeLayout)

            ZStack {
                feltBackground

                Group {
                    if showingDealAnimation {
                        if let table = tableView {
                            dealAnimationTable(
                                table: table,
                                decision: decisionView ?? table,
                                interactive: isInteractive,
                                layout: layout)
                        } else {
                            EmptyView()
                        }
                    } else if let snapshot = endOfHandSnapshot {
                        handCompleteView(snapshot)
                            .padding(layout.isPhoneLandscape ? 8 : 16)
                    } else if let table = tableView {
                        activeView(
                            table: table,
                            decision: decisionView ?? table,
                            interactive: isInteractive,
                            layout: layout)
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
                .onChange(of: settings.showFullTrickHistory) { _, enabled in
                    if !enabled { selectedTrickHistorySeat = nil }
                }
                .onChange(of: dealAnimationToken(for: tableView)) { _, token in
                    startDealAnimationIfNeeded(token)
                }
                .onChange(of: tableView?.toAct) { _, _ in
                    syncActiveSeat()
                }
                .onAppear {
                    startDealAnimationIfNeeded(dealAnimationToken(for: tableView))
                    displayedActiveSeat = tableView?.toAct
                }
            }
        }
    }

    var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.2)
            Text("Waiting for the table…")
                .font(TableTypography.display(.callout))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Move the turn-highlight to the seat now on the clock. During bidding we
    /// hold a beat first, so the seat that just bid stays lit long enough for
    /// the eye to register its amount before the highlight advances.
    private func syncActiveSeat() {
        let target = tableView?.toAct
        let bidding = tableView?.phase == .bidding
        activeSeatToken &+= 1
        let token = activeSeatToken
        if bidding && displayedActiveSeat != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard token == activeSeatToken else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    displayedActiveSeat = target
                }
            }
        } else {
            displayedActiveSeat = target
        }
    }

    // MARK: Active hand

    /// The phone "mini tabletop": scores + phase up top, the four-direction
    /// trick board in the middle (the local player at the bottom edge), the
    /// fanned hand below. Bidding controls sit just above the hand so the
    /// seat chips still show the other bids; trump/discard still float over
    /// the empty center.
    func activeView(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        let actionActive = interactive && isActionPhase(decision.phase)
        let biddingActive = interactive && decision.phase == .bidding
        let centerActionActive = actionActive && !biddingActive
        return ZStack {
            if layout.isPhoneLandscape {
                landscapeActiveView(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    centerActionActive: centerActionActive,
                    layout: layout)
            } else {
                portraitActiveView(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    centerActionActive: centerActionActive,
                    layout: layout)
            }

            trickHistoryOverlay(table, layout: layout)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.85), value: actionActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectedTrickHistorySeat)
    }

    func portraitActiveView(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        actionActive: Bool,
        biddingActive: Bool,
        centerActionActive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        ZStack {
            VStack(spacing: layout.stackSpacing) {
                boardHeader(table, decision: decision, interactive: interactive, layout: layout)

                if showsBidHistoryStrip(table) {
                    bidHistoryStrip(table, layout: layout)
                }

                if table.phase == .misdealDecision {
                    misdealBanner(table, decision: decision, interactive: interactive, layout: layout)
                }

                Spacer(minLength: 0)

                boardArea(table, layout: layout)
                    .scaleEffect(centerActionActive ? 0.92 : 1.0, anchor: .top)

                Spacer(minLength: 0)

                footerStrip(table, layout: layout)

                actionPrompt(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    layout: layout)

                handSection(table: table, decision: decision, interactive: interactive, layout: layout)
            }
            .padding(.horizontal, layout.contentHorizontalPadding)
            .padding(.top, layout.contentTopPadding)
            .padding(.bottom, layout.contentBottomPadding)

            if centerActionActive {
                actionPanel(decision, layout: layout)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, 70)   // bias up, clear of the hand
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }

    func landscapeActiveView(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        actionActive: Bool,
        biddingActive: Bool,
        centerActionActive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        HStack(alignment: .top, spacing: layout.landscapeColumnSpacing) {
            VStack(spacing: layout.stackSpacing) {
                boardHeader(table, decision: decision, interactive: interactive, layout: layout)
                Spacer(minLength: 0)
                boardArea(table, layout: layout)
                Spacer(minLength: 0)
            }
            .frame(width: layout.landscapeBoardColumnWidth, height: layout.contentHeight, alignment: .top)

            VStack(spacing: layout.stackSpacing) {
                Color.clear.frame(height: layout.landscapeControlTopGap)

                if showsBidHistoryStrip(table) {
                    bidHistoryStrip(table, layout: layout)
                }

                if table.phase == .misdealDecision {
                    misdealBanner(table, decision: decision, interactive: interactive, layout: layout)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                footerStrip(table, layout: layout)

                actionPrompt(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    layout: layout)

                if centerActionActive {
                    actionPanel(decision, layout: layout)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                handSection(table: table, decision: decision, interactive: interactive, layout: layout)
            }
            .frame(width: layout.landscapeInfoColumnWidth, height: layout.contentHeight, alignment: .top)
        }
        .padding(.horizontal, layout.contentHorizontalPadding)
        .padding(.top, layout.contentTopPadding)
        .padding(.bottom, layout.contentBottomPadding)
    }

    @ViewBuilder
    func actionPrompt(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        actionActive: Bool,
        biddingActive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        if biddingActive {
            biddingActionPanel(decision, layout: layout)
                .padding(.horizontal, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !actionActive {
            if interactive && decision.phase == .trickPlay {
                hintText("Highlighted cards are legal.", layout: layout)
            } else if !interactive {
                hintText(caughtUp ? "Waiting for other players…" : "Watching play…", layout: layout)
            }
        }
    }

    func dealAnimationTable(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        let actionActive = interactive && isActionPhase(decision.phase)
        let biddingActive = interactive && decision.phase == .bidding
        let centerActionActive = actionActive && !biddingActive
        if layout.isPhoneLandscape {
            return AnyView(
                landscapeDealAnimationTable(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    centerActionActive: centerActionActive,
                    layout: layout))
        }
        return AnyView(portraitDealAnimationTable(
            table: table,
            decision: decision,
            interactive: interactive,
            actionActive: actionActive,
            biddingActive: biddingActive,
            centerActionActive: centerActionActive,
            layout: layout))
    }

    func portraitDealAnimationTable(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        actionActive: Bool,
        biddingActive: Bool,
        centerActionActive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        return VStack(spacing: 8) {
            boardHeader(table, decision: decision, interactive: false, layout: layout)
                .hidden()

            if table.phase == .misdealDecision {
                misdealBanner(table, decision: decision, interactive: false, layout: layout)
                    .hidden()
            }

            Spacer(minLength: 0)

            boardArea(table,
                      showLiveCards: false,
                      showsIdleText: false,
                      dealAnimationTrigger: dealAnimationTrigger,
                      layout: layout)
                .scaleEffect(centerActionActive ? 0.92 : 1.0, anchor: .top)

            Spacer(minLength: 0)

            footerStrip(table, layout: layout)
                .hidden()

            if biddingActive {
                biddingActionPanel(decision, layout: layout)
                    .padding(.horizontal, 4)
                    .hidden()
            } else if !actionActive {
                if interactive && decision.phase == .trickPlay {
                    hintText("Highlighted cards are legal.", layout: layout)
                        .hidden()
                } else if !interactive {
                    hintText(caughtUp ? "Waiting for other players…" : "Watching play…", layout: layout)
                        .hidden()
                }
            }

            handSection(table: table, decision: decision, interactive: interactive, layout: layout)
                .hidden()
        }
        .padding(.horizontal, layout.contentHorizontalPadding)
        .padding(.top, layout.contentTopPadding)
        .padding(.bottom, layout.contentBottomPadding)
        .allowsHitTesting(false)
    }

    func landscapeDealAnimationTable(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        actionActive: Bool,
        biddingActive: Bool,
        centerActionActive: Bool,
        layout: GameBodyLayout
    ) -> some View {
        HStack(alignment: .top, spacing: layout.landscapeColumnSpacing) {
            VStack(spacing: layout.stackSpacing) {
                boardHeader(table, decision: decision, interactive: false, layout: layout)
                    .hidden()
                Spacer(minLength: 0)
                boardArea(table,
                          showLiveCards: false,
                          showsIdleText: false,
                          dealAnimationTrigger: dealAnimationTrigger,
                          layout: layout)
                    .scaleEffect(centerActionActive ? 0.92 : 1.0, anchor: .top)
                Spacer(minLength: 0)
            }
            .frame(width: layout.landscapeBoardColumnWidth, height: layout.contentHeight, alignment: .top)

            VStack(spacing: layout.stackSpacing) {
                Color.clear.frame(height: layout.landscapeControlTopGap)

                if showsBidHistoryStrip(table) {
                    bidHistoryStrip(table, layout: layout)
                        .hidden()
                }

                if table.phase == .misdealDecision {
                    misdealBanner(table, decision: decision, interactive: false, layout: layout)
                        .hidden()
                }

                footerStrip(table, layout: layout)
                    .hidden()

                actionPrompt(
                    table: table,
                    decision: decision,
                    interactive: interactive,
                    actionActive: actionActive,
                    biddingActive: biddingActive,
                    layout: layout)
                .hidden()

                if centerActionActive {
                    actionPanel(decision, layout: layout)
                        .hidden()
                }

                Spacer(minLength: 0)

                handSection(table: table, decision: decision, interactive: interactive, layout: layout)
                    .hidden()
            }
            .frame(width: layout.landscapeInfoColumnWidth, height: layout.contentHeight, alignment: .top)
        }
        .padding(.horizontal, layout.contentHorizontalPadding)
        .padding(.top, layout.contentTopPadding)
        .padding(.bottom, layout.contentBottomPadding)
        .allowsHitTesting(false)
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
