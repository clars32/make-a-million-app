//
//  MonteCarloAgent+Traditional.swift
//  Make-a-Million
//
//  The TRADITIONAL decision stack: the legible, capability-laddered agent.
//  Every move it plays has a nameable principled reason; strength rises by
//  adding principles, deepening table-reading, and planning ahead at forks —
//  never by random error. See `ai_rewrite.md` §2 for the model.
//
//  Selection order (§2.4):
//    1. Principle decides — most positions collapse to one decisive candidate.
//    2. Genuine fork — ≥2 candidates carry different, each-valid principles;
//       resolved by a bounded search confined to that set (when plansAhead),
//       else by deterministic shortlist priority.
//    3. True tie — lightly randomized over the residual that no principle can
//       separate, drawn from the agent's seedBox so replays stay reproducible.
//
//  This stack is reached only when `difficulty.style == .traditional`
//  (the novice/casual/skilled/expert ladder). The `.adaptive` side-door keeps
//  using the search stack in MonteCarloAgent+TrickPlay / +Bidding unchanged.
//

import Foundation

extension MonteCarloAgent {

    // MARK: - Traditional trick play (Phase 2 stub — real logic lands in Phase 3)

    func decideTrickPlayTraditional(_ view: PlayerView, legal: [Move]) -> Move {
        decideTrickPlay(view, legal: legal)
    }

    // MARK: - Traditional bidding (Phase 2 stub — real logic lands in Phase 4)

    func decideBidTraditional(_ view: PlayerView, legal: [Move]) -> Move {
        decideBid(view, legal: legal)
    }
}
