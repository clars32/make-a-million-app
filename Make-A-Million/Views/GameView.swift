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
            onCaptureLastView: { lastView = $0 })
        .onAppear {
            guard tableView == nil, session.finished == nil, !session.running else { return }
            session.startNewMatch(dealSeed: dealSeed)
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

    var teamAName: String {
        guard seatNames.count == 4 else { return "Team A" }
        return "\(seatNames[0]) + \(seatNames[2])"
    }
    
    var teamBName: String {
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

    var waitingView: some View {
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
    func activeView(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
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

    func dealAnimationTable(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
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
