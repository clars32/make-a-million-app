//
//  BiddingDebugViews.swift
//  Make-a-Million
//
//  The bidding-visibility pass, view side. Same intent as the trick-history
//  panel you already built: make the state the engine tracks LEGIBLE so
//  bidding can be judged instead of guessed at. Deliberately plain.
//
//  TWO DISTINCT THINGS, with a deliberate boundary between them:
//
//   • The bid SEQUENCE is PUBLIC (everyone at the table hears it) and is
//     presented by GameView.bidHistoryPanel, riding the redacted PlayerView
//     (view.bidHistory) exactly like completed tricks do. This file embeds
//     only a compact recap of it inside the reveal, for self-containment.
//
//   • HandRevealPanel — every seat's DEALT hand, declarer, trump, contract
//     result. This is HIDDEN information. It does NOT come from PlayerView;
//     it comes from GameState.debugReveal(), a separate path that exists
//     only at handComplete and is never handed to an agent. Gated behind a
//     flag so you can switch it off for honest play. Showing this mid-hand,
//     or routing it through PlayerView, would let the Monte Carlo agent
//     "see" hidden hands when it samples — the one thing the architecture
//     must never allow.
//

import SwiftUI

/// Flip to `false` for real play; `true` while tuning bidding.
enum BiddingDebug {
    static let revealHands = true
}

// MARK: - Shared seat labels (kept consistent with GameView's convention)

private func seatShort(_ p: PlayerID) -> String {
    ["You", "W", "N", "E"][p.raw]
}
private func seatName(_ p: PlayerID) -> String {
    ["South (You)", "West", "North", "East"][p.raw]
}

private extension BidAction {
    var label: String {
        switch self {
        case .pass:            return "pass"
        case .bid(let amount): return "$\(amount / 1000)k"
        }
    }
}

// MARK: - Bid list (private to the reveal; your GameView.bidHistoryPanel is
// the primary, richer presentation used everywhere else — this is only the
// compact recap embedded inside the debug reveal so it stays self-contained).

private struct BidLogList: View {
    let log: [BidRecord]

    var body: some View {
        if log.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup("Bidding recap (\(log.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(log.enumerated()), id: \.offset) { i, rec in
                        HStack(spacing: 8) {
                            Text("\(i + 1).")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .leading)
                            Text(seatName(rec.player))
                                .font(.caption)
                                .frame(width: 96, alignment: .leading)
                            Text(rec.action.label)
                                .font(.caption).bold()
                                .foregroundStyle(rec.action.isPass
                                                 ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(.primary))
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

private extension BidAction {
    var isPass: Bool { if case .pass = self { return true }; return false }
}

// MARK: - End-of-hand hand reveal (hidden info — debug only)

struct HandRevealPanel: View {
    let reveal: DebugReveal?

    var body: some View {
        if BiddingDebug.revealHands, let r = reveal {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack {
                    Text("Hand reveal (debug)")
                        .font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    contractBadge(r)
                }

                ForEach(Seats.all, id: \.raw) { seat in
                    seatRow(seat, r)
                }

                if !r.dealtWidow.isEmpty {
                    HStack(spacing: 6) {
                        Text("Widow")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(width: 70, alignment: .leading)
                        ForEach(Array(r.dealtWidow.enumerated()), id: \.offset) { _, c in
                            Text(c.shortLabel).font(.caption2)
                                .foregroundStyle(c.tint)
                        }
                    }
                }

                BidLogList(log: r.bidHistory)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        } else {
            EmptyView()
        }
    }

    private func contractBadge(_ r: DebugReveal) -> some View {
        let made = r.made
        let text: String = {
            guard let c = r.contract, let d = r.declarer else { return "no contract" }
            return "\(seatShort(d)) bid $\(c / 1000)k — "
                 + (made ? "made ($\(r.bidTeamGross / 1000)k)"
                         : "SET ($\(r.bidTeamGross / 1000)k)")
        }()
        return Text(text)
            .font(.caption).bold()
            .foregroundStyle(made ? Color.green : Color.red)
    }

    private func seatRow(_ seat: PlayerID, _ r: DebugReveal) -> some View {
        let hand = (r.dealtHands[seat] ?? [])
            .sorted { handKey($0) > handKey($1) }
        let isDeclarer = (seat == r.declarer)
        return HStack(alignment: .top, spacing: 6) {
            Text(seatShort(seat))
                .font(.caption2)
                .fontWeight(isDeclarer ? .bold : .regular)
                .foregroundStyle(isDeclarer ? AnyShapeStyle(.primary)
                                            : AnyShapeStyle(.secondary))
                .frame(width: 70, alignment: .leading)
            FlowRow(spacing: 4) {
                ForEach(Array(hand.enumerated()), id: \.offset) { _, c in
                    Text(c.shortLabel)
                        .font(.caption2).foregroundStyle(c.tint)
                }
            }
        }
    }

    // Local sort key (high → low), independent of GameView's private one.
    private func handKey(_ c: Card) -> Int {
        switch c {
        case .colored(let col, let r): return 100 + col.rawValue * 13 + r.rawValue
        case .tiger: return 90
        case .bull:  return 89
        case .bear:  return 88
        }
    }
}
