//
//  Players.swift
//  Make-a-Million
//
//  Seat identity, fixed partnerships, the Move type (the ONLY thing an agent
//  ever produces), and a seeded RNG so any hand is reconstructable from
//  (seed, [moves]). That reconstructability is what later makes local/remote
//  play nearly free — we ship moves, not state.
//

import Foundation

// MARK: - Seats & partnerships

/// Stable seat identity, 0..<4 clockwise. Independent of device/connection so
/// it survives reconnects in a later milestone.
struct PlayerID: Hashable, Codable {
    let raw: Int
    init(_ raw: Int) { self.raw = raw }
}

enum Seats {
    static let count = 4
    static let all = (0..<count).map(PlayerID.init)

    /// Fixed partnerships: seats 0 & 2 vs seats 1 & 3 (partners sit opposite).
    static func partner(of p: PlayerID) -> PlayerID { PlayerID((p.raw + 2) % count) }
    static func team(of p: PlayerID) -> Int { p.raw % 2 }   // 0 or 1

    /// Clockwise next seat.
    static func next(_ p: PlayerID) -> PlayerID { PlayerID((p.raw + 1) % count) }
}

// MARK: - Bids

/// A bid is a dollar amount. Opening minimum $175,000; each raise at least
/// $10,000 above the standing high bid. A player may pass instead.
enum BidAction: Codable, Hashable {
    case bid(Int)
    case pass
}

enum Bidding {
    static let openingMinimum = 175_000
    static let raiseIncrement = 10_000
}

// MARK: - Moves
//
// The ONLY thing an agent (human / AI / remote) ever submits. Value-typed,
// Codable, tiny — it crosses the UI boundary now and the network boundary
// later, unchanged.

enum Move: Codable, Hashable {
    /// During the bidding phase: place a bid or pass.
    case bid(BidAction)

    /// High bidder requesting a misdeal redeal (only legal when the engine
    /// has flagged this player misdeal-eligible). Modeled as a real move so
    /// the optional rule lives in the state machine, not in UI glue.
    case callMisdeal

    /// High bidder declining misdeal and proceeding (only legal when eligible).
    case declineMisdeal

    /// High bidder discarding three cards after taking the widow.
    case discardWidow([Card])

    /// High bidder naming the trump color (after any widow discard).
    case nameTrump(CardColor)

    /// Playing one card to the current trick.
    case play(Card)
}

// MARK: - Seeded deal RNG

/// Small deterministic PRNG (SplitMix64). The deal is the only randomness in
/// the engine; seeding it means (seed, [moves]) fully reconstructs any hand.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
