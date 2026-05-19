//
//  GameView.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/19/26.
//


//
//  GameView.swift
//  Make-a-Million
//
//  POLISH PASS 1 — card-to-trick travel (matchedGeometry) + the continuity
//  fix that has to exist for it (or any trick animation) to be possible.
//
//  THE CONTINUITY FIX (this revision):
//
//   `human.pending` is nil BETWEEN every turn — cleared the instant you
//   submit, stays nil while the bots play, set again at your next turn.
//   The old body fell back to `startView` during that gap, tearing the
//   whole hierarchy down and rebuilding it on every play. matchedGeometry
//   cannot survive that. So: while a hand is running, we hold the last
//   PlayerView and keep the active layout MOUNTED (inert) through the gap.
//   No more startView flash; the namespace identities persist.
//
//   This is pure presentation state. It does NOT gate the engine, does NOT
//   make the engine wait, does NOT mutate the model. It only stops the view
//   from throwing its own screen away between turns.
//
//  KNOWN, STILL OPEN (next pass, deliberately not faked here):
//
//   The view only re-renders on YOUR turns. It never sees the trick fill
//   in, so your played card is already in lastTrick by the next frame —
//   there is no resting frame for it to travel to. Real trick animation
//   needs the view to RECEIVE the trick as it progresses (a read-only
//   presentation feed drained at a view-side cadence, engine never
//   blocked). That needs GameRunner / HumanAgent and is its own focused
//   pass. The matchedGeometry wiring below is correct and starts working
//   the moment that feed exists; until then it has nothing to interpolate
//   to, and that's expected — not a bug to chase.
//
//  GUARDRAIL, held: animation OBSERVES state, never DRIVES it. The tap
//  still calls `human.submit(.play(card))` — identical to the old button.
//

import SwiftUI

struct GameView: View {
    @StateObject private var session = GameSession()
    @State private var dealSeed: UInt64 = 64

    var body: some View {
        GameBody(session: session,
                 human: session.human,
                 dealSeed: $dealSeed)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GameBody: View {
    @ObservedObject var session: GameSession
    @ObservedObject var human: HumanAgent
    @Binding var dealSeed: UInt64

    /// Shared geometry namespace. Same `CardKey` in the hand and in the
    /// trick → SwiftUI interpolates the frame between them.
    @Namespace private var cardNS

    /// The last view we were handed. Lets us keep the active layout mounted
    /// during the between-turns gap so the hierarchy stays continuous.
    @State private var lastView: PlayerView? = nil

    private let teamAName = "You + North"
    private let teamBName = "West + East"

    /// Changes whenever `pending` transitions (incl. to/from nil). Drives
    /// the lastView capture without assuming PlayerView is Equatable.
    private var pendingTick: Int {
        guard let p = human.pending else { return -1 }
        return animationToken(p)
    }

    /// Live turn → the real pending view. Between turns while a hand is
    /// still running → the remembered view (keeps the layout mounted).
    /// Nothing running and nothing pending → no view (start screen).
    private var renderView: PlayerView? {
        if let p = human.pending { return p }
        if session.running { return lastView }
        return nil
    }

    var body: some View {
        Group {
            if let final = session.finished {
                handCompleteView(final)
            } else if let view = renderView {
                activeView(view, interactive: human.pending != nil)
            } else {
                startView
            }
        }
        .onChange(of: pendingTick) { _, _ in
            if let p = human.pending { lastView = p }
        }
    }

    // MARK: Start

    private var startView: some View {
        VStack(spacing: 16) {
            Text("Make-a-Million").font(.largeTitle).bold()
            Text("You are seat 1 (South). West, North, East are random bots.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Deal a hand") { session.start(dealSeed: dealSeed) }
                .buttonStyle(.borderedProminent)
            Text("deal seed \(dealSeed)")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Active hand

    private func activeView(_ view: PlayerView, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            scoreBar(view)

            statusLine(view)

            if view.phase == .bidding || !view.bidHistory.isEmpty {
                bidHistoryPanel(records: view.bidHistory, opener: view.opener)
            }

            if let last = view.lastTrick {
                lastTrickPanel(last)
            }

            if let trick = view.currentTrick, !trick.plays.isEmpty {
                trickInProgress(trick)
            }

            Divider()

            Text("Your hand (\(view.myHand.count))")
                .font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(keyedHand(view.myHand), id: \.key) { entry in
                    handCard(entry.card, view: view, interactive: interactive)
                }
            }

            Divider()

            movePanel(view, interactive: interactive)

            Spacer(minLength: 4)

            if !view.completedTricks.isEmpty {
                historyPanel(view)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.80),
                   value: animationToken(view))
        .opacity(interactive ? 1.0 : 0.97)
    }

    @ViewBuilder
    private func handCard(_ card: Card, view: PlayerView, interactive: Bool) -> some View {
        let playable = isPlayable(card, in: view)
        let tappable = interactive && view.phase == .trickPlay && playable

        Group {
            if tappable {
                Button {
                    human.submit(.play(card))
                } label: {
                    cardChip(card, faded: false)
                }
                .buttonStyle(.plain)
            } else {
                cardChip(card, faded: !playable)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: Score bar

    private func scoreBar(_ view: PlayerView) -> some View {
        let live = view.liveHandScore
        return HStack {
            teamScoreColumn(teamAName,
                            live: live[0, default: 0],
                            match: view.matchScore[0, default: 0],
                            alignment: .leading)
            Spacer()
            Text("vs").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            teamScoreColumn(teamBName,
                            live: live[1, default: 0],
                            match: view.matchScore[1, default: 0],
                            alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    private func teamScoreColumn(_ name: String,
                                 live: Int,
                                 match: Int,
                                 alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text("Hand $\(live / 1000)k")
                .font(.title3).bold().monospacedDigit()
            Text("Match $\(match / 1000)k")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private func statusLine(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(view.phase.headline).font(.title3).bold()
            HStack(spacing: 12) {
                if let hb = view.highBid, let who = view.highBidder {
                    Text("High bid $\(hb / 1000)k — \(seatName(who))")
                }
                if let t = view.trump {
                    HStack(spacing: 4) {
                        Text("Trump:")
                        Circle().fill(t.swatch).frame(width: 10, height: 10)
                        Text(t.displayName)
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Last completed trick

    private func lastTrickPanel(_ last: CompletedTrickInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last trick").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(seatName(last.winner)) took it · $\(last.value / 1000)k")
                    .font(.caption).bold()
                    .foregroundStyle(last.winner.raw % 2 == 0 ? Color.green : Color.orange)
            }
            HStack(spacing: 8) {
                ForEach(keyedPlays(last.plays), id: \.key) { entry in
                    VStack(spacing: 2) {
                        Text(seatShort(entry.play.player))
                            .font(.caption2)
                            .foregroundStyle(entry.play.player == last.winner
                                             ? AnyShapeStyle(.primary)
                                             : AnyShapeStyle(.tertiary))
                        cardChip(entry.play.card, faded: entry.play.player != last.winner)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
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
                            .matchedGeometryEffect(id: cardKey(entry.play.card),
                                                   in: cardNS)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
            }
        }
    }

    // MARK: Move panel

    @ViewBuilder
    private func movePanel(_ view: PlayerView, interactive: Bool) -> some View {
        Text("Your move — \(view.phase.headline)")
            .font(.caption).foregroundStyle(.secondary)

        if !interactive {
            Text("Waiting for other players…")
                .font(.callout).foregroundStyle(.secondary).italic()
        } else if view.legalMoves.isEmpty {
            Text("Waiting for other players…")
                .font(.callout).foregroundStyle(.secondary).italic()
        } else if view.phase == .bidding && bidOptionsOnly(view).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("The bidding has run past you — you can only pass.")
                    .font(.caption).foregroundStyle(.orange)
                FlowRow(spacing: 6) {
                    ForEach(Array(view.legalMoves.enumerated()), id: \.offset) { _, m in
                        Button(m.label) { human.submit(m) }
                            .font(.callout).buttonStyle(.bordered)
                    }
                }
            }
        } else if view.phase == .trickPlay {
            Text("Tap a card in your hand to play it.")
                .font(.caption).foregroundStyle(.secondary).italic()
        } else {
            FlowRow(spacing: 6) {
                ForEach(Array(view.legalMoves.enumerated()), id: \.offset) { _, move in
                    Button(move.label) { human.submit(move) }
                        .font(.callout).buttonStyle(.bordered)
                }
            }
        }
    }

    private func bidOptionsOnly(_ view: PlayerView) -> [Move] {
        view.legalMoves.filter {
            if case .bid(.bid) = $0 { return true }; return false
        }
    }

    // MARK: History

    private func historyPanel(_ view: PlayerView) -> some View {
        DisclosureGroup("Trick history (\(view.completedTricks.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(view.completedTricks.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 6) {
                        Text("#\(i + 1)").font(.caption2).foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .leading)
                        ForEach(Array(t.plays.enumerated()), id: \.offset) { _, pc in
                            Text(pc.card.shortLabel)
                                .font(.caption2)
                                .foregroundStyle(pc.card.tint)
                                .fontWeight(pc.player == t.winner ? .bold : .regular)
                        }
                        Spacer()
                        Text("\(seatShort(t.winner)) $\(t.value/1000)k")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    // MARK: Hand complete

    private func handCompleteView(_ s: GameState) -> some View {
        let a = s.matchScore[0, default: 0]
        let b = s.matchScore[1, default: 0]
        return VStack(spacing: 14) {
            Text("Hand complete").font(.title2).bold()
            Text("\(teamAName): $\(a / 1000)k")
            Text("\(teamBName): $\(b / 1000)k").foregroundStyle(.secondary)
            if !s.bidHistory.isEmpty {
                bidHistoryPanel(records: s.bidHistory, opener: Seats.next(s.dealer))
            }
            HandRevealPanel(reveal: s.debugReveal())
            Button("Deal another") {
                dealSeed &+= 1
                session.reset()
                lastView = nil
                session.start(dealSeed: dealSeed)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func bidHistoryPanel(records: [BidRecord], opener: PlayerID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Bid history").font(.caption).foregroundStyle(.secondary)
                Text("Opener: \(seatName(opener))")
                    .font(.caption2).bold()
                    .foregroundStyle(.blue)
                Spacer()
            }
            if records.isEmpty {
                Text("Waiting for \(seatName(opener)) to open")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        HStack(spacing: 4) {
                            Text(seatShort(record.player))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if record.player == opener {
                                Text("opens")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            Text(bidHistoryLabel(record.action))
                                .font(.caption2).bold().monospacedDigit()
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(bidHistoryTint(record, opener: opener).opacity(0.14)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(bidHistoryTint(record, opener: opener).opacity(0.45), lineWidth: 1))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Helpers

    private func seatName(_ p: PlayerID) -> String {
        ["South (You)", "West", "North", "East"][p.raw]
    }
    private func seatShort(_ p: PlayerID) -> String {
        ["You", "W", "N", "E"][p.raw]
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

    private func bidHistoryTint(_ record: BidRecord, opener: PlayerID) -> Color {
        if record.player == opener { return .blue }
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
        case .colored(let color, let rank):
            return (0, color.rawValue, rank.rawValue)
        case .tiger:
            return (1, 0, 0)
        case .bull:
            return (1, 0, 1)
        case .bear:
            return (1, 0, 2)
        }
    }

    // MARK: Card identity for matched geometry
    //
    // Unique (group,color,rank) per distinct card. Assumes no duplicate
    // cards in a deal — true for any standard trick-taking deck.

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

    private func animationToken(_ v: PlayerView) -> Int {
        v.myHand.count &* 1000
            &+ (v.currentTrick?.plays.count ?? 0) &* 13
            &+ v.completedTricks.count
    }

    private func cardChip(_ card: Card, faded: Bool) -> some View {
        Text(card.shortLabel)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(card.tint.opacity(faded ? 0.12 : 0.28)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(card.tint.opacity(faded ? 0.3 : 0.9), lineWidth: 1))
            .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

/// Stable, card-derived identity for matchedGeometryEffect and ForEach.
struct CardKey: Hashable {
    let g: Int   // group: 0 = colored, 1 = beast
    let c: Int   // color rawValue (0 for beasts)
    let r: Int   // rank rawValue / beast discriminator
}

/// Minimal wrapping layout so a 13–16 chip hand wraps instead of overflowing.
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
