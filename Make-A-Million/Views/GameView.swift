//
//  GameView.swift
//  Make-A-Million
//

import SwiftUI

struct GameView: View {
    @StateObject private var session = GameSession()
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)

    var body: some View {
        SoloGameBody(session: session,
                     human: session.human,
                     dealSeed: $dealSeed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            startAction: { session.start(dealSeed: dealSeed) },
            dealAnother: {
                dealSeed = .random(in: .min ... .max)
                session.reset()
                lastView = nil
                session.start(dealSeed: dealSeed)
            },
            dealSeed: dealSeed,
            onCaptureLastView: { lastView = $0 })
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
    let startAction: (() -> Void)?
    let dealAnother: (() -> Void)?
    let dealSeed: UInt64
    let onCaptureLastView: ((PlayerView) -> Void)?

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
            LinearGradient(
                colors: [Color.teal.opacity(0.2), Color.blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea()

            Group {
                if let snapshot = endOfHandSnapshot {
                    handCompleteView(snapshot)
                } else if let table = tableView {
                    activeView(
                        table: table,
                        decision: decisionView ?? table,
                        interactive: isInteractive)
                } else if let startAction {
                    startView(action: startAction)
                } else {
                    waitingView
                }
            }
            .padding()
            .onChange(of: pendingTick) { _, _ in
                if let v = decisionView, isInteractive {
                    onCaptureLastView?(v)
                    if v.phase != .widowDiscard { discardSelection = [] }
                }
            }
            .onChange(of: displayTick) { _, _ in
                if let d = tableView { onCaptureLastView?(d) }
            }
            .onChange(of: tableView?.phase) { _, newPhase in
                guard let newPhase else { return }
                bidHistoryExpanded = (newPhase == .bidding)
            }
        }
    }

    // MARK: Start (solo only)

    private func startView(action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text("Make-a-Million").font(.system(.largeTitle, design: .rounded)).bold()
            Text("You are seat 1 (South). West, North, East are random bots.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Deal a hand", action: action)
                .buttonStyle(.borderedProminent)
            Text("deal seed \(dealSeed)")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text("Waiting for the table…")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Active hand

    private func activeView(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // ADD: A dedicated top row for the controls
            HStack {
                Spacer()
                // This is where your End/Leave button (passed from wrapper) lives
                if let dealAction = startAction { /* ... */ }
            }
            
            scoreBar(table) // Scores are now safely below the top row
            statusLine(table)

            if table.phase == .bidding || !table.bidHistory.isEmpty {
                bidHistoryPanel(records: table.bidHistory, opener: table.opener)
            }

            if let widow = table.widow, !widow.isEmpty {
                widowPanel(widow, highBidder: table.highBidder)
            }

            if let last = table.lastTrick {
                lastTrickPanel(last)
            }

            if let trick = table.currentTrick, !trick.plays.isEmpty {
                trickInProgress(trick)
            }

            Divider()

            Text("Your hand (\(table.myHand.count))")
                .font(.caption).foregroundStyle(.secondary)

            let hand = keyedHand(table.myHand)

            GeometryReader { proxy in
                let n = hand.count
                let cardWidth: CGFloat = 60
                let rotationPad: CGFloat = 30
                let usable = max(cardWidth, proxy.size.width - rotationPad)
                let preferredOverlap: CGFloat = 30
                let naturalWidth = CGFloat(n) * cardWidth - CGFloat(max(0, n - 1)) * preferredOverlap
                let spacing: CGFloat = (n <= 1 || naturalWidth <= usable)
                    ? -preferredOverlap
                    : (usable - CGFloat(n) * cardWidth) / CGFloat(n - 1)
                let centerIndex = Double(n - 1) / 2.0

                let anglePerCard: Double = 3.5
                let maxAngle = anglePerCard * centerIndex
                let outerDip: CGFloat = 12
                let radius: CGFloat = maxAngle > 0
                    ? outerDip / CGFloat(1 - cos(maxAngle * .pi / 180))
                    : 1

                HStack(spacing: spacing) {
                    ForEach(Array(hand.enumerated()), id: \.element.key) { index, entry in
                        let offset = Double(index) - centerIndex
                        let angleDeg = offset * anglePerCard
                        let angleRad = angleDeg * .pi / 180
                        let dip = radius * CGFloat(1 - cos(angleRad))

                        handCard(entry.card, decision: decision, interactive: interactive, totalCards: n)
                            .rotationEffect(.degrees(angleDeg), anchor: .bottom)
                            .offset(y: dip)
                            .offset(y: discardSelection.contains(entry.card) ? -8 : 0)
                            .zIndex(Double(index))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.top, 25)
            .padding(.bottom, 45)
            .frame(height: 130)
            .frame(maxWidth: .infinity)

            Divider()

            movePanel(decision, interactive: interactive)

            Spacer(minLength: 4)

            if BiddingDebug.showTrickHistory && !table.completedTricks.isEmpty {
                historyPanel(table)
            }
        }
        .opacity(interactive ? 1.0 : 0.97)
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
                    cardChip(card, faded: false, selected: selected, totalCards: totalCards)
                }
                .buttonStyle(.plain)
            } else {
                let faded = decision.phase == .widowDiscard ? !discardSelectable : false
                cardChip(card, faded: faded, selected: selected, totalCards: totalCards)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: Score bar

    private func scoreBar(_ view: PlayerView) -> some View {
        let live = view.liveHandScore
        return HStack {
            teamScoreColumn(teamAName, live: live[0, default: 0], match: view.matchScore[0, default: 0], alignment: .leading)
            Spacer()
            Text("vs").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            teamScoreColumn(teamBName, live: live[1, default: 0], match: view.matchScore[1, default: 0], alignment: .trailing)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func teamScoreColumn(_ name: String, live: Int, match: Int, alignment: HorizontalAlignment) -> some View {
        // Determine if this is the "You" team (Team A)
        let isMyTeam = name.contains("You") || name.contains(seatNames[0])
        
        return VStack(alignment: alignment, spacing: 2) {
            Text(name)
                .font(.caption)
                .bold()
                .foregroundStyle(isMyTeam ? .blue : .secondary) // Highlight my team
            
            Text("Hand $\(live / 1000)k")
                .font(.system(.title3, design: .rounded).bold().monospacedDigit())
            
            Text("Match $\(match / 1000)k")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(isMyTeam ? Color.blue.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func statusLine(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(view.phase.headline).font(.system(.title3, design: .rounded)).bold()
            if let t = view.trump { trumpBadge(t, prominent: view.phase == .trickPlay) }
        }
    }

    private func trumpBadge(_ color: CardColor, prominent: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color.swatch).frame(width: prominent ? 14 : 10, height: prominent ? 14 : 10)
            Text(color.displayName)
                .font(prominent ? .subheadline : .caption)
                .fontWeight(prominent ? .bold : .semibold)
                .foregroundStyle(color.swatch)
        }
        .padding(.horizontal, prominent ? 10 : 7)
        .padding(.vertical, prominent ? 6 : 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.swatch.opacity(prominent ? 0.22 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.swatch.opacity(prominent ? 0.75 : 0.5), lineWidth: prominent ? 2 : 1))
        .accessibilityLabel("Trump: \(color.displayName)")
    }

    // MARK: Last completed trick

    private func lastTrickPanel(_ last: CompletedTrickInfo) -> some View {
        HStack(spacing: 8) {
            Text("Last trick").font(.caption).foregroundStyle(.secondary)
            ForEach(keyedPlays(last.plays), id: \.key) { entry in
                VStack(spacing: 2) {
                    Text(seatShort(entry.play.player))
                        .font(.system(size: 9))
                        .foregroundStyle(entry.play.player == last.winner ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    miniCardChip(entry.play.card, faded: entry.play.player != last.winner)
                }
            }
            Spacer()
            Text("\(seatShort(last.winner)) · $\(last.value / 1000)k")
                .font(.system(.caption, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(last.winner.raw % 2 == 0 ? Color.green : Color.orange)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func trickInProgress(_ trick: Trick) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trick in progress").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(keyedPlays(trick.plays), id: \.key) { entry in
                    VStack(spacing: 2) {
                        Text(seatShort(entry.play.player))
                            .font(.caption2).foregroundStyle(.tertiary)
                        cardChip(entry.play.card, faded: false)
                            .matchedGeometryEffect(id: cardKey(entry.play.card), in: cardNS)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                    }
                }
            }
        }
    }

    // MARK: Move panel

    @ViewBuilder
    private func movePanel(_ view: PlayerView, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your move — \(view.phase.headline)").font(.caption).foregroundStyle(.secondary)

            if view.phase == .handComplete {
                Text("Hand complete.").font(.callout).foregroundStyle(.secondary)
            } else if !interactive && !caughtUp {
                Text("Watching play…").font(.callout).foregroundStyle(.secondary).italic()
            } else if !interactive || view.legalMoves.isEmpty {
                Text("Waiting for other players…").font(.callout).foregroundStyle(.secondary).italic()
            } else if view.phase == .trickPlay {
                Text("Tap a card in your hand to play it.").font(.caption).foregroundStyle(.secondary).italic()
            } else if view.phase == .widowDiscard {
                widowDiscardPanel(view)
            } else {
                let passMove = view.legalMoves.first { $0.label.lowercased().contains("pass") }
                let bidMoves = view.legalMoves.filter { !$0.label.lowercased().contains("pass") }

                VStack(spacing: 14) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(bidMoves.enumerated()), id: \.offset) { index, move in
                                    let isSelected = index == selectedBidIndex
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                            selectedBidIndex = index
                                            proxy.scrollTo(index, anchor: .center)
                                        }
                                    } label: {
                                        Text(move.label.replacingOccurrences(of: "Bid ", with: ""))
                                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                                            .foregroundStyle(isSelected ? .white : .primary)
                                            .padding(.horizontal, 16)
                                            .frame(height: 44)
                                            .background {
                                                Capsule(style: .continuous).fill(isSelected ? Color.blue : Color.secondary.opacity(0.15))
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
                        Button { submit(bidMoves[selectedBidIndex]) } label: {
                            Text("Bid \(bidMoves[selectedBidIndex].label.replacingOccurrences(of: "Bid ", with: ""))")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Capsule(style: .continuous).fill(Color.blue))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
                .padding(.horizontal)
            }
        }
    }

    private func widowDiscardPanel(_ view: PlayerView) -> some View {
        let count = discardSelection.count
        let ready = count == 3
        let legalMove = ready ? matchingWidowDiscardMove(selection: discardSelection, in: view) : nil

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tap three cards in your hand to discard. Tiger, Bull, and Bear cannot be discarded.")
                .font(.caption).foregroundStyle(.secondary)
            if ready && legalMove == nil {
                Text("That discard isn't legal — you can only discard money cards when you have no other choice.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text("\(count) of 3 selected").font(.system(.callout, design: .rounded)).monospacedDigit()
                Spacer()
                Button("Discard selected") {
                    if let move = legalMove { submit(move); discardSelection = [] }
                }
                .buttonStyle(.borderedProminent)
                .disabled(legalMove == nil)
            }
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
        return !card.isSpecial
    }

    private func toggleDiscardSelection(_ card: Card) {
        if discardSelection.contains(card) {
            discardSelection.remove(card)
        } else if discardSelection.count < 3 {
            discardSelection.insert(card)
        }
    }

    // MARK: History

    private func historyPanel(_ view: PlayerView) -> some View {
        DisclosureGroup("Trick history (\(view.completedTricks.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(view.completedTricks.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 6) {
                        Text("#\(i + 1)").font(.caption2).foregroundStyle(.tertiary).frame(width: 26, alignment: .leading)
                        ForEach(Array(t.plays.enumerated()), id: \.offset) { _, pc in
                            Text(pc.card.shortLabel)
                                .font(.caption2).foregroundStyle(pc.card.tint)
                                .fontWeight(pc.player == t.winner ? .bold : .regular)
                        }
                        Spacer()
                        Text("\(seatShort(t.winner)) $\(t.value/1000)k")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    // MARK: Hand complete

    private func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        let a = s.matchScore[0, default: 0]
        let b = s.matchScore[1, default: 0]
        let matchOver = s.matchWinner != nil
        return VStack(spacing: 14) {
            Text(matchOver ? "Match complete" : "Hand complete").font(.title2).bold()
            if let winner = s.matchWinner {
                Text("\(winner == 0 ? teamAName : teamBName) wins!")
                    .font(.headline).foregroundStyle(.green)
            }
            Text("\(teamAName): $\(a / 1000)k")
            Text("\(teamBName): $\(b / 1000)k").foregroundStyle(.secondary)
            if !s.bidHistory.isEmpty {
                bidHistoryPanel(records: s.bidHistory, opener: s.opener)
            }
            HandRevealPanel(reveal: s.debugReveal)
            if let dealAnother {
                Button("Deal another", action: dealAnother).buttonStyle(.borderedProminent)
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

    private func widowPanel(_ widow: [Card], highBidder: PlayerID?) -> some View {
        HStack(spacing: 8) {
            Text("Widow").font(.caption).foregroundStyle(.secondary)
            ForEach(keyedHand(widow), id: \.key) { entry in
                miniCardChip(entry.card)
            }
            Spacer()
            if let bidder = highBidder {
                Text(seatShort(bidder))
                    .font(.caption).bold()
                    .foregroundStyle(bidder.raw % 2 == 0 ? Color.green : Color.orange)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func sortedHand(_ hand: [Card]) -> [Card] {
        hand.sorted { lhs, rhs in
            let l = handSortKey(lhs)
            let r = handSortKey(rhs)
            if l.group != r.group { return l.group > r.group }
            if l.color != r.color { return l.color > r.color }
            return l.rank > r.rank
        }
    }

    private func handSortKey(_ card: Card) -> (group: Int, color: Int, rank: Int) {
        switch card {
        case .colored(let color, let rank): return (0, color.rawValue, rank.rawValue)
        case .tiger: return (1, 0, 0)
        case .bull: return (1, 0, 1)
        case .bear: return (1, 0, 2)
        }
    }

    private func cardKey(_ card: Card) -> CardKey {
        let k = handSortKey(card)
        return CardKey(g: k.group, c: k.color, r: k.rank)
    }

    private func keyedHand(_ hand: [Card]) -> [(key: CardKey, card: Card)] {
        sortedHand(hand).map { (cardKey($0), $0) }
    }

    private func keyedPlays(_ plays: [PlayedCard]) -> [(key: CardKey, play: PlayedCard)] {
        plays.map { (cardKey($0.card), $0) }
    }

    static func animationToken(_ v: PlayerView) -> Int {
        var token = v.myHand.count &* 1000
        token &+= (v.currentTrick?.plays.count ?? 0) &* 13
        token &+= v.completedTricks.count &* 100
        token &+= v.bidHistory.count &* 7
        return token
    }

    private func cardChip(_ card: Card, faded: Bool, selected: Bool = false, highlighted: Bool = false, totalCards: Int = 1) -> some View {
        let safeTint = card.tint == .primary ? Color.black : card.tint
        let isDense = totalCards > 12

        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor
                            : (highlighted ? Color.green : Color.gray.opacity(0.3)),
                        lineWidth: (selected || highlighted) ? 2.5 : 0.5))
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.shortLabel)
                        .font(.system(size: isDense ? 10 : 13, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Circle()
                        .fill(safeTint)
                        .frame(width: 6, height: 6)
                }
                .padding(.top, 6)
                .padding(.leading, 6)
                .foregroundStyle(safeTint),
                alignment: .topLeading)
            .shadow(
                color: .black.opacity(selected ? 0.3 : 0.15),
                radius: selected ? 8 : 2,
                y: selected ? 4 : 1)
            .frame(width: 60, height: 85)
            .opacity(faded ? 0.5 : 1.0)
            .scaleEffect(selected ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
    }

    private func miniCardChip(_ card: Card, faded: Bool = false) -> some View {
        let safeTint = card.tint == .primary ? Color.black : card.tint
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            .overlay(
                HStack(spacing: 2) {
                    Text(card.shortLabel)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Circle().fill(safeTint).frame(width: 4, height: 4)
                }
                .padding(.horizontal, 4)
                .foregroundStyle(safeTint))
            .frame(width: 38, height: 26)
            .opacity(faded ? 0.5 : 1.0)
    }
}

struct CardKey: Hashable {
    let g: Int
    let c: Int
    let r: Int
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
