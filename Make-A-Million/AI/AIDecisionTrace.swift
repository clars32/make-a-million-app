//
//  AIDecisionTrace.swift
//  Make-a-Million
//
//  The missing half of the hand log. HandLog reconstructs WHAT happened from
//  the final GameState with perfect information — but it cannot show WHY an AI
//  chose a move, because that reasoning (the heuristic shortlist, the per-
//  candidate MCTS score, and the table-read flags that picked the branch) is
//  computed transiently inside MonteCarloAgent and thrown away. When a play
//  looks wrong from the outside (e.g. "why spend the Tiger to overtake a
//  partner who was already winning?") the log alone can't distinguish a
//  principled choice from a valuation bug.
//
//  This is a process-wide, opt-in side channel the agent writes to ONLY when
//  file logging is on. It buffers one hand's worth of decisions; HandLog reads
//  the buffer at handComplete and interleaves each decision under the trick it
//  belongs to. Matching is by (seat, chosen card) — unique within a hand,
//  since every card is played exactly once — so the agent never needs to know
//  the hand index or trick number.
//
//  It records ONLY real top-level decisions: MCTS rollouts move via
//  PlayoutPolicy, not through the agent, so playout noise never lands here.
//  When disabled (normal play, and every AIArena self-play run) `isEnabled`
//  is false and the agent skips building the trace entirely — zero cost.
//
//  Thread-safety: chooseMove can run off the main actor, so the buffer is
//  guarded by a lock and the type is @unchecked Sendable.
//

import Foundation

nonisolated final class AIDecisionTrace: @unchecked Sendable {

    static let shared = AIDecisionTrace()

    /// One scored candidate from the trick-play shortlist.
    struct Candidate {
        let card: Card
        /// Mean team NET (our gross − their gross) over the sampled worlds,
        /// in dollars. Higher is better; this is the number MCTS ranks on.
        let meanNet: Double
        /// How many determinized worlds actually scored this candidate.
        let samples: Int
    }

    /// A single trick-play decision by an AI seat.
    struct PlayDecision {
        let seat: PlayerID
        let chosen: Card
        /// True if the blunder dice fired and a non-best move was taken.
        let blundered: Bool
        /// Shortlist with scores, already sorted best-first.
        let candidates: [Candidate]
        /// Table-read snapshot that explains which shortlist branch fired —
        /// pre-formatted by the agent because HandLog has no inference layer.
        let notes: [String]
    }

    /// A single bidding decision by an AI seat.
    struct BidDecision {
        let seat: PlayerID
        let chosen: String          // "$185k" or "pass"
        let valuationGross: Int      // HandEvaluator's expected gross for the hand
        let ceiling: Int             // the match-aware bid ceiling actually used
        let notes: [String]
    }

    private let lock = NSLock()
    private var enabled = false
    private var plays: [PlayDecision] = []
    private var bids: [BidDecision] = []

    /// Cheap gate the agent checks before doing any trace work.
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    /// Reset the buffer for a fresh hand and set whether capture is active.
    /// Called by the session as each hand is dealt.
    func beginHand(enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
        plays.removeAll()
        bids.removeAll()
    }

    func record(_ d: PlayDecision) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        plays.append(d)
    }

    func record(_ d: BidDecision) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        bids.append(d)
    }

    /// The whole hand's captured reasoning, for HandLog to render.
    func snapshot() -> (plays: [PlayDecision], bids: [BidDecision]) {
        lock.lock(); defer { lock.unlock() }
        return (plays, bids)
    }
}
