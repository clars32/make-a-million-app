//
//  SavedSoloGame.swift
//  Make-a-Million
//
//  The resume model. The engine is built so any hand is "reconstructable from
//  (seed, [moves])" (see Players.swift / GameEngine.swift) — this file is that
//  promise cashed in. We persist the match-progression scalars plus the
//  current hand's move log, and resuming re-deals the same seed and replays
//  the log to the exact saved position. We ship moves, not state.
//

import Foundation

// MARK: - Recorded move

/// One applied move plus the seat that made it — the unit of the replayable
/// move log. Recorded as the runner applies each move (including the forced
/// auto-misdeal redeal) and replayed verbatim through the same reducer to
/// reconstruct a hand. The pair is self-validating: `applying` rejects a move
/// whose `player` is not on turn, so a corrupted log fails loudly rather than
/// resuming into a wrong position.
nonisolated struct RecordedMove: Codable, Hashable, Sendable {
    let player: PlayerID
    let move: Move
}

// MARK: - Saved solo match

/// A saved, resumable solo match. Everything needed to reconstruct the exact
/// position:
///
///   • The match-progression scalars. `matchSeedBase &+ handIndex` fixes the
///     deal of the current hand (the same arithmetic `GameSession` uses), and
///     `dealer` / `carry` carry the rotation and running score into it.
///   • The optional rules FROZEN onto the current hand at deal time. Replay
///     must use these, never the live settings: the deal's initial phase
///     (auto-misdeal) and per-move legality (house rules) depend on them, so a
///     settings change between sessions can't be allowed to invalidate the log.
///   • The current hand's move log, oldest first (empty at the start of a hand).
///
/// Re-deal the current hand from `matchSeedBase &+ handIndex` under these
/// rules, replay `moves`, and the state is identical to the one saved.
nonisolated struct SavedSoloGame: Codable, Equatable {

    // Match progression — fixes which hand, dealt how, with what score.
    var matchSeedBase: UInt64
    var handIndex: UInt64
    var dealer: PlayerID
    var carry: [Int: Int]

    // Rules frozen onto the current hand at deal time (see note above).
    var misdealRule: MisdealRule
    var endgameRule: EndgameTiebreak
    var houseRules: HouseRules

    /// The current hand's move log, oldest first.
    var moves: [RecordedMove]

    /// When this snapshot was written — for a "last played" hint on the menu.
    var savedAt: Date

    /// 1-based hand number for display.
    var handNumber: Int { Int(handIndex) + 1 }
}
