//
//  EndgameSolver.swift
//  Make-a-Million
//
//  Exact alpha-beta over the ENDGAME of a determinized world. Within a
//  sampled full-information world the last few tricks are a tiny
//  perfect-information game — small enough to solve outright instead of
//  approximating with a greedy PlayoutPolicy walk.
//
//  WHY: every validated strength gain so far (widow-lock, rolloutTopPull)
//  came from making the futures the search imagines more accurate. The
//  greedy rollout is the limit on that accuracy: it plays the endgame with
//  one-card-lookahead heuristics, and its mistakes are SYSTEMATIC — the
//  same blind spot fires in every rollout, so it does not cancel between
//  root candidates the way random noise does (the Bull/Bear endplay leak
//  documented on `rolloutSpecialEscape` is exactly this class). A strong
//  human counts the last few tricks exactly; this solver is that, per
//  sampled world. Where the rollout's tail was wrong, the solve is right;
//  where it was right, the solve merely agrees faster.
//
//  DESIGN:
//   • Engine-driven. Moves come from `state.legalMoves(for:)` and are
//     applied with `state.applying(_:by:)` — no rule is re-implemented, so
//     specials, the Bull/Bear lead restriction, house rules (trump must be
//     broken), and hand settlement are all engine-true by construction.
//     (Same covenant as AIWorld: the AI never re-implements a rule.)
//   • Two-team minimax. Seats on `myTeam` maximise the leaf utility,
//     the other two seats minimise it. The leaf (`utility` in
//     MonteCarloAgent) is zero-sum between the teams — team net is a
//     difference, and the optional match-win term is complementary
//     (P(we win) = 1 − P(they win)) — so alpha-beta is sound.
//   • Policy-first move ordering. The greedy PlayoutPolicy move is tried
//     first at every node; it is usually right, which is what makes
//     alpha-beta cut. Ordering only affects SPEED, never the value.
//   • Node budget. A safety valve against pathological width (every seat
//     void everywhere). On exhaustion the solve returns nil and the caller
//     falls back to the greedy rollout — never a wrong answer, just a
//     softer one. At the intended gate (≤ 4 tricks remaining) the budget
//     does not trip in practice.
//
//  ENGINE BINDING: GameState.{phase, toAct, hands, matchScore,
//  legalMoves(for:), applying(_:by:)} ; Seats.team(of:) ; PlayoutPolicy.move.
//

import Foundation

enum EndgameSolver {

    /// Default node budget per solve. ~Thousands of engine steps; a solve at
    /// the ≤4-tricks gate typically uses a few hundred. See header.
    static let defaultNodeBudget = 20_000

    /// Exact minimax value of `state` for `myTeam`, where `leaf` scores a
    /// settled (`.handComplete`) state. Returns nil if the node budget is
    /// exhausted (caller falls back to a greedy rollout) or the state is not
    /// in trick play.
    ///
    /// `policyGuess` supplies the move to try first at each node for alpha-beta
    /// ordering. Pass the SAME flagged `PlayoutPolicy` the rollouts use, so the
    /// ordering matches the policy that is usually right (better cuts). Ordering
    /// only affects SPEED, never the value; nil falls back to the default-flag
    /// policy move.
    static func solve(_ state: GameState,
                      myTeam: Int,
                      nodeBudget: Int = defaultNodeBudget,
                      policyGuess: ((GameState) -> Move)? = nil,
                      leaf: (GameState) -> Double) -> Double? {
        var budget = nodeBudget
        return alphabeta(state, myTeam: myTeam,
                         alpha: -.infinity, beta: .infinity,
                         budget: &budget, policyGuess: policyGuess, leaf: leaf)
    }

    // MARK: - Search

    private static func alphabeta(_ state: GameState,
                                  myTeam: Int,
                                  alpha: Double,
                                  beta: Double,
                                  budget: inout Int,
                                  policyGuess: ((GameState) -> Move)?,
                                  leaf: (GameState) -> Double) -> Double? {
        if state.phase == .handComplete { return leaf(state) }
        guard state.phase == .trickPlay else { return nil }   // defensive
        budget -= 1
        if budget < 0 { return nil }

        let seat = state.toAct
        let moves = ordered(state.legalMoves(for: seat), state: state, seat: seat,
                            policyGuess: policyGuess)
        guard !moves.isEmpty else { return nil }              // engine invariant

        let maximizing = Seats.team(of: seat) == myTeam
        var a = alpha
        var b = beta
        var best = maximizing ? -Double.infinity : .infinity
        for mv in moves {
            guard let next = try? state.applying(mv, by: seat) else { continue }
            guard let v = alphabeta(next, myTeam: myTeam, alpha: a, beta: b,
                                    budget: &budget, policyGuess: policyGuess, leaf: leaf)
            else { return nil }                               // budget tripped below
            if maximizing {
                if v > best { best = v }
                if best > a { a = best }
            } else {
                if v < best { best = v }
                if best < b { b = best }
            }
            if a >= b { break }                               // cut
        }
        return best.isFinite ? best : nil
    }

    /// Try the greedy policy's move first — it is usually best, which is
    /// what makes alpha-beta prune. Pure speed heuristic; the value is the
    /// same in any order. Uses the caller's flagged policy when supplied so
    /// the guess matches the rollout policy (tighter cuts on tiers whose
    /// `PlayoutPolicy` flags change its preferred move, e.g. `topPull`).
    private static func ordered(_ moves: [Move],
                                state: GameState,
                                seat: PlayerID,
                                policyGuess: ((GameState) -> Move)?) -> [Move] {
        guard moves.count > 1 else { return moves }
        let guess = policyGuess?(state) ?? PlayoutPolicy.move(in: state, seat: seat)
        guard let idx = moves.firstIndex(of: guess), idx != 0 else { return moves }
        var out = moves
        out.remove(at: idx)
        out.insert(guess, at: 0)
        return out
    }
}
