//
//  ISMCTS.swift
//  Make-a-Million
//
//  Single-observer Information Set Monte Carlo Tree Search (SO-ISMCTS,
//  Cowling/Powley/Whitehouse 2012) for trick play.
//
//  WHY this exists. `decideTrickPlay`'s default search is determinized depth-1
//  PIMC: sample a full-information world, apply each ROOT candidate, then play
//  the rest of the hand with the greedy `PlayoutPolicy`, and average. Two
//  defects fall out, both inherent to PIMC and untunable:
//
//    • STRATEGY FUSION — every rollout plays the future already KNOWING the
//      hidden cards, so the search over-credits lines that only work because
//      the rollout "peeked" (it always finds the Tiger), and assigns no value
//      to discovery plays or flexible holdings that a real player needs.
//    • A WEAK IMAGINED FUTURE-SELF — the rollout butchers lines that need
//      follow-up precision (a two-step trump pull, an endplay), so they are
//      systematically undervalued at the root.
//
//  SO-ISMCTS fixes the first by building ONE tree over the root player's
//  information sets and sampling a FRESH determinization each iteration: a move
//  is only explored where it is legal in the current world, so the search
//  reasons about choices made WITHOUT seeing the hidden cards, marginalising
//  over them via the determinizations. It softens the second by searching
//  opponents' and partner's replies (UCB nodes) instead of trusting the greedy
//  rollout for them — the rollout only finishes the tail past the tree frontier.
//
//  Design choices specific to this game:
//    • All plays are PUBLIC once made, so a tree node = a concrete public
//      play-sequence; determinizations differ only in the still-hidden hands,
//      which is exactly what `Determinizer` samples.
//    • Two TEAMS, zero-sum. Rewards are stored once in the ROOT team's
//      perspective; selection negates the mean at opposing-team nodes, so
//      opponents play adversarially and partner cooperatively (the partner is
//      on the root team) — no separate opponent model needed.
//    • Availability-count UCB (the ISMCTS correction): a child's exploration
//      term uses how often its move was LEGAL, not the parent's total visits,
//      so a move that is only occasionally available isn't unfairly starved.
//
//  ENGINE BINDING: GameState.legalMoves(for:) / applying(_:by:) / phase /
//  toAct ; Seats.team(of:) ; Move. No rule is re-implemented — legality and
//  resolution come from the engine, exactly like EndgameSolver and the
//  determinizer.
//

import Foundation

enum ISMCTS {

    /// One node = a public play-sequence position. Children are keyed by the
    /// move (card) that reaches them; their stats accumulate across all
    /// determinizations that pass through this node.
    final class Node {
        var children: [Move: Node] = [:]
        /// Times this node's move was SELECTED (rollouts backed up through it).
        var visits = 0
        /// Sum of ROOT-team utility over those visits.
        var totalReward = 0.0
        /// Times this node's move was AVAILABLE (legal) at its parent — the
        /// ISMCTS exploration denominator.
        var availability = 0
    }

    /// Per-root-candidate result handed back to the caller, which turns it into
    /// the mean-net scoring the existing tie-break / blunder / trace tail wants.
    struct RootStat {
        let move: Move
        let visits: Int
        let total: Double
    }

    /// Run `iterations` of SO-ISMCTS and return each root candidate's stats.
    ///
    /// - rootCandidates: the root player's moves to search (the shortlist). The
    ///   root player's own hand is known, so every candidate is legal in every
    ///   determinization — the root node never needs availability bookkeeping.
    /// - rootTeam: the team whose utility `leafValue` returns.
    /// - sampleWorld: a FRESH determinized `GameState` with the root player to
    ///   act (nil if sampling momentarily failed — that iteration is skipped).
    /// - leafValue: roll a leaf `GameState` out to terminal and return the
    ///   ROOT-team utility (the agent passes its `evaluateWorld`).
    /// - policyMove: the move to try FIRST when expanding (PlayoutPolicy), so
    ///   the tree grows along plausible lines; nil falls back to random.
    /// - nextRandom: the caller's seeded RNG stream (keeps decisions
    ///   reproducible, like the rest of the AI).
    static func search(rootCandidates: [Move],
                       rootTeam: Int,
                       iterations: Int,
                       explore: Double = 0.7,
                       valueScale: Double = 400_000,
                       sampleWorld: () -> GameState?,
                       leafValue: (GameState) -> Double,
                       policyMove: (GameState) -> Move?,
                       nextRandom: () -> UInt64) -> [RootStat] {
        guard !rootCandidates.isEmpty else { return [] }
        let root = Node()

        for _ in 0..<iterations {
            guard var state = sampleWorld() else { continue }
            var path: [(node: Node, move: Move)] = []
            var node = root

            // ---- Selection + single-node expansion ----
            while true {
                // The root's choices are gated to the caller's candidate set;
                // deeper, every legal move in THIS world is a live option.
                let available = (node === root)
                    ? rootCandidates
                    : state.legalMoves(for: state.toAct)
                guard !available.isEmpty else { break }   // nothing to do → rollout

                // Count availability for the children that already exist.
                for m in available { node.children[m]?.availability += 1 }
                let untried = available.filter { node.children[$0] == nil }

                let move: Move
                let expanding: Bool
                if !untried.isEmpty {
                    move = expansionPick(untried, state: state,
                                         policyMove: policyMove, nextRandom: nextRandom)
                    expanding = true
                } else if let sel = selectUCB(node, available: available,
                                              maximizing: Seats.team(of: state.toAct) == rootTeam,
                                              explore: explore, valueScale: valueScale) {
                    move = sel
                    expanding = false
                } else {
                    break
                }

                let child: Node
                if let existing = node.children[move] {
                    child = existing
                } else {
                    child = Node()
                    node.children[move] = child
                    child.availability += 1            // available this iteration too
                }

                guard let next = try? state.applying(move, by: state.toAct) else { break }
                state = next
                path.append((node, move))
                node = child
                if expanding || state.phase == .handComplete { break }
            }

            // ---- Rollout from the frontier ----
            let reward = leafValue(state)

            // ---- Backpropagation (reward stored root-team perspective) ----
            for step in path {
                let c = step.node.children[step.move]!
                c.visits += 1
                c.totalReward += reward
            }
        }

        return root.children.map {
            RootStat(move: $0.key, visits: $0.value.visits, total: $0.value.totalReward)
        }
    }

    /// Try the policy's preferred move first (so the tree grows along plausible
    /// lines); otherwise pick a random untried move for diversity.
    private static func expansionPick(_ untried: [Move], state: GameState,
                                      policyMove: (GameState) -> Move?,
                                      nextRandom: () -> UInt64) -> Move {
        if let pm = policyMove(state), untried.contains(pm) { return pm }
        return untried[Int(nextRandom() % UInt64(untried.count))]
    }

    /// UCB1 with the ISMCTS availability denominator. `maximizing` is true at a
    /// node where the side to act is on the ROOT team (so it wants the stored
    /// reward up); false at an opposing-team node (it wants it down).
    private static func selectUCB(_ node: Node, available: [Move],
                                  maximizing: Bool, explore: Double,
                                  valueScale: Double) -> Move? {
        var best: Move? = nil
        var bestScore = -Double.infinity
        for m in available {
            guard let c = node.children[m], c.visits > 0 else { continue }
            let mean = c.totalReward / Double(c.visits)
            let exploit = (maximizing ? mean : -mean) / valueScale
            let exploreTerm = c.availability > 0
                ? explore * (log(Double(c.availability)) / Double(c.visits)).squareRoot()
                : 0
            let score = exploit + exploreTerm
            if score > bestScore { bestScore = score; best = m }
        }
        return best
    }
}
