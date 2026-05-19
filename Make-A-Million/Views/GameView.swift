//
//  GameView.swift
//  Make-a-Million
//
//  Visibility pass. Still deliberately PLAIN — no card art, no animation.
//  The goal is to make the state the engine already tracks LEGIBLE: what
//  each seat just played and who took the trick, the running team score,
//  the trick history, and a clear message when you were outbid and have no
//  legal bid. This doubles as the instrument panel for building the AI next.
//

import SwiftUI

struct GameView: View {
    @StateObject private var session = GameSession()
    @State private var dealSeed: UInt64 = 32

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

    private let teamAName = "You + North"
    private let teamBName = "West + East"

    var body: some View {
        if let final = session.finished {
            handCompleteView(final)
        } else if let view = human.pending {
            activeView(view)
        } else {
            startView
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

    private func activeView(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            scoreBar(view)

            statusLine(view)

            if view.phase == .bidding || !view.bidHistory.isEmpty {
                bidHistoryPanel(records: view.bidHistory, opener: view.opener)
            }

            // What just happened: the last completed trick + who took it.
            if let last = view.lastTrick {
                lastTrickPanel(last)
            }

            // Trick in progress.
            if let trick = view.currentTrick, !trick.plays.isEmpty {
                trickInProgress(trick)
            }

            Divider()

            Text("Your hand (\(view.myHand.count))")
                .font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(Array(sortedHand(view.myHand).enumerated()), id: \.offset) { _, card in
                    cardChip(card, faded: !isPlayable(card, in: view))
                }
            }

            Divider()

            movePanel(view)

            Spacer(minLength: 4)

            // Collapsible trick history — instrument panel for AI tuning.
            if !view.completedTricks.isEmpty {
                historyPanel(view)
            }
        }
    }

    // MARK: Score bar (prominent, always visible)

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
                ForEach(Array(last.plays.enumerated()), id: \.offset) { _, pc in
                    VStack(spacing: 2) {
                        Text(seatShort(pc.player))
                            .font(.caption2)
                            .foregroundStyle(pc.player == last.winner
                                             ? AnyShapeStyle(.primary)
                                             : AnyShapeStyle(.tertiary))
                        cardChip(pc.card, faded: pc.player != last.winner)
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
                ForEach(Array(trick.plays.enumerated()), id: \.offset) { _, pc in
                    VStack(spacing: 2) {
                        Text(seatShort(pc.player))
                            .font(.caption2).foregroundStyle(.tertiary)
                        cardChip(pc.card, faded: false)
                    }
                }
            }
        }
    }

    // MARK: Move panel — handles the "shut out of bidding" case explicitly

    @ViewBuilder
    private func movePanel(_ view: PlayerView) -> some View {
        Text("Your move — \(view.phase.headline)")
            .font(.caption).foregroundStyle(.secondary)

        if view.legalMoves.isEmpty {
            // Should not happen on your turn (engine guarantees a move), but
            // if the runner is waiting on a bot this branch shows why the UI
            // is idle rather than appearing frozen.
            Text("Waiting for other players…")
                .font(.callout).foregroundStyle(.secondary).italic()
        } else if view.phase == .bidding && bidOptionsOnly(view).isEmpty {
            // You can still pass but every raise is above any sane ceiling —
            // i.e. you've effectively been bid out. Say so plainly.
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
        } else {
            FlowRow(spacing: 6) {
                ForEach(Array(view.legalMoves.enumerated()), id: \.offset) { _, move in
                    Button(move.label) { human.submit(move) }
                        .font(.callout).buttonStyle(.bordered)
                }
            }
        }
    }

    /// Non-pass bid options, used only to detect the "all you can do is pass"
    /// situation for a clearer message.
    private func bidOptionsOnly(_ view: PlayerView) -> [Move] {
        view.legalMoves.filter {
            if case .bid(.bid) = $0 { return true }; return false
        }
    }

    // MARK: History (instrument panel)

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
            Button("Deal another") {
                dealSeed &+= 1
                session.reset()
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
