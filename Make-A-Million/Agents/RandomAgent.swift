//
//  RandomAgent.swift
//  Make-a-Million
//
//  Picks uniformly at random from the legal moves. It plays badly on purpose.
//
//  Its job is NOT to be a good opponent. It is:
//    1. Scaffolding — the thing that drives a full game loop end to end so
//       the loop itself is testable with zero UI and zero real AI.
//    2. The baseline — the dumb opponent the real Monte Carlo AI must
//       decisively beat. If the MCTS agent can't crush this, it's broken.
//
//  Deterministic when seeded, so a (seed, agent-seeds) pair reproduces an
//  entire self-played game — the same reconstructability property the engine
//  has, extended to the agents. Invaluable for debugging "it did something
//  weird on turn 31".
//

import Foundation

struct RandomAgent: PlayerAgent {
    let name: String
    private let rngBox: RNGBox

    init(name: String = "Random", seed: UInt64) {
        self.name = name
        self.rngBox = RNGBox(seed: seed)
    }

    func chooseMove(from view: PlayerView) async -> Move {
        let moves = view.legalMoves
        // The engine guarantees this is non-empty on your turn. If it were
        // empty we'd rather crash loudly in development than silently stall.
        precondition(!moves.isEmpty,
                     "RandomAgent asked to move with no legal moves — engine invariant violated")
        let idx = rngBox.nextInt(upperBound: moves.count)
        return moves[idx]
    }
}

/// Reference box so the agent can stay a value-typed `struct` while still
/// advancing RNG state across calls (PlayerAgent.chooseMove is non-mutating
/// by design — agents are cheap to pass around).
final class RNGBox {
    private var rng: SeededRNG
    init(seed: UInt64) { self.rng = SeededRNG(seed: seed) }

    func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(rng.next() % UInt64(upperBound))
    }
}
