//
//  MonteCarloAgent.swift
//  Make-a-Million
//
//  REWRITE — a hybrid agent that plays the way a strong human would
//  describe playing. Heuristics drive the parts where they outperform
//  rollouts (bidding, discard, trump, misdeal); MCTS over determinized
//  worlds drives the parts where they don't (trick play). The shortlist
//  passed to MCTS is itself heuristic, so the search spends its samples
//  on choices that are actually plausible.
//
//  Public API unchanged. GameSession and AIArena keep working untouched.
//
//  ─────────────────────────────────────────────────────────────────────
//  PRINCIPLES, with where they live:
//
//   Bidding (heuristic, this file)
//     • Hand-valuation: HandEvaluator (money, trump length, voids,
//       specials, partner support, widow EV) — the single biggest
//       skill in the game.
//     • Reluctant to bid past partner: `partnerRespect`. If partner is
//       the high bidder I only override when MY estimate is decisively
//       better than their bid.
//     • Slow to outbid by more than needed: when raising an opponent,
//       I bid the MINIMUM legal raise — strong players don't bid
//       themselves up. Aggression only affects WHETHER I bid, not how
//       much.
//     • Score-aware: when our team is near $1M, tighten the ceiling
//       (avoid going set and giving them back the game). When far
//       behind with opponents near $1M, loosen it.
//     • Style variation: easy/medium/hard differ in aggression,
//       partner-respect, and blunder rate so the four bots don't feel
//       identical.
//
//   Misdeal (heuristic, this file)
//     • Agreement-mode redeal vote: KEEP the hand (decline the redeal) when
//       it values at/above the opening floor; otherwise agree to the redeal.
//       A redeal is triggered by ANY seat being money-poor, so a strong hand
//       of ours isn't surrendered just because another seat is short.
//
//   Widow discard + trump (heuristic, this file)
//     • Joint optimisation: for each shortlisted discard, try all 4
//       trump colors; pick the (discard, trump) pair with the highest
//       HandEvaluator score for the resulting 13-card hand.
//     • Shortlist drops the lowest non-money, non-special cards first
//       (the engine forbids needless money/special discards anyway).
//
//   Trick play (heuristic shortlist + MCTS, this file)
//     • Heuristic shortlist from TableInference encodes:
//         – Pull trump when declarer with length + Tiger loose.
//         – $40k first time a color is led.
//         – Cash sure winners in side suits.
//         – Save big money when an opponent could still trump.
//         – Dump money on partner's safe trick (and Bull doubles it).
//         – Bear on opponent's money trick we can't take.
//         – Last to play: take cheaply or shed lowest.
//     • MCTS scores each shortlisted move by mean team NET over
//       sampled worlds. PlayoutPolicy is now tactically aware, so
//       fewer samples carry more signal.
//  ─────────────────────────────────────────────────────────────────────
//
//  ENGINE BINDING: PlayerAgent ; PlayerView.* ; GameState.applying(_:by:)
//  & .legalMoves(for:) & .phase & .matchScore & .capturedByTeam ;
//  Seats.{team, partner, next, all, count} ; BidAction ; Move cases ;
//  Card.{moneyValue, isMoney, isSpecial, effectiveColor} ;
//  Bidding.{openingMinimum, raiseIncrement, bidIncrement}.
//

import Foundation

struct MonteCarloAgent: PlayerAgent {

    nonisolated struct Difficulty {
        /// Determinized worlds sampled per trick-play decision. More =
        /// stronger but slower. With the new tactical playout 12-30 is
        /// often enough; old version needed 40+.
        var samples: Int
        /// Probability of taking a deliberately non-best move (fun, not
        /// frustration). 0 = always best.
        var blunderRate: Double
        /// Multiplier on hand value when deciding how far to bid. <1 is
        /// cautious because a missed bid is set back in full.
        var bidAggression: Double
        /// How much the agent defers to a partner who already has the
        /// high bid. 1.0 = strongly defer (only override on monsters);
        /// 0.0 = ignore partner.
        var partnerRespect: Double
        /// How strongly match-score situation modifies the bid ceiling.
        /// 0 = ignore score; 1 = full conservative-ahead / aggressive-behind.
        var matchAwareness: Double
        /// Trick-play shortlist size. Smaller = faster but might miss
        /// the best move. 3-5 is the sweet spot.
        var trickCandidates: Int
        /// How strongly bid history biases the determinized worlds (passers
        /// get weaker hands, bidders stronger). 0 = ignore bids (uniform
        /// sampling); higher = read the auction more like a strong human.
        var bidLeanStrength: Double = 0.0
        /// HARD deduction in world sampling: place the declarer's
        /// un-discardable widow cards (Tiger/Bull/Bear always; money unless
        /// revealed in the discard announcement) into the declarer's sampled hand instead
        /// of letting them scatter to random seats. A PROVABLE fact the sampler
        /// otherwise ignored (it averaged over impossible worlds). Now ON for
        /// every tier — it only ever removes impossible worlds, and self-play
        /// measured it positive (paired +~7pp, lower set-rate). Kept as a field,
        /// not hard-wired, so it stays A/B-able (turn it off on one side).
        var deduceWidowHoldings: Bool = true
        /// Extreme-only deeper table-reading. Currently: count-exhaustion voids
        /// — once every card of a color is accounted for (in my hand or already
        /// played), the other seats are void in it even if they never failed to
        /// follow, so the agent foresees a ruff of an otherwise-"boss" side card
        /// whose suit has run dry. Provably correct, but TIERED (off below
        /// Extreme) to keep Extreme a distinctly stronger card-counter.
        var deepInference: Bool = false
        /// SHAPE prior for world sampling: the declarer NAMED trump, so they
        /// are likely LONG in it. Biases trump cards (any rank) toward the
        /// declarer's sampled hand. Soft prior (shifts the distribution, never
        /// breaks a count/void/widow constraint). 0 = off; higher = stronger
        /// pull (≈ exp(value) odds multiplier per trump card).
        ///
        /// PARKED AT 0 (June 2026): measured −~2pp at BOTH 0.4 and 0.8 in
        /// paired self-play. Hypothesis: `bidLeanStrength` already drifts high
        /// trump to the (bidder) declarer, so adding a length bias on top
        /// over-concentrates trump there and the defenders under-model their
        /// own/partner's trump. Lever retained for a future refinement — bias
        /// only LOW trump, or pair it with a reduced `bidLeanStrength`.
        var declarerTrumpBias: Double = 0.0
        /// HARD world-INFERENCE: play-consistency rejection sampling. After a
        /// world is sampled, replay the public trick history through the ENGINE
        /// and reject the world if it forces a hidden seat to have made a
        /// PROVABLY-DOMINATED past play — a blunder no rational line takes,
        /// given the cards this world dealt them. Two certainty-gated checks
        /// (see `Determinizer.isConsistentWithPlay`), split so each is
        /// independently A/B-able, both restricted to the seat being LAST to
        /// play so the trick outcome was already certain:
        ///   (A) `filterDominatedDonation` — the seat donated money / the Bull
        ///       (which DOUBLES the enemy take) into a trick certainly lost to
        ///       the opponents when a worthless throwaway was legal; and
        ///   (B) `filterBearDecline` — the seat declined the loose Bear on a
        ///       fat (>= bearDeclineFloor) trick certainly lost to the
        ///       opponents when the Bear was legal.
        ///
        /// PARKED — both OFF (June 12 2026). Conceived as the named successor
        /// to the parked exact-endgame gates >=3 (exact play amplifies world
        /// quality → sharper worlds first). Measured the OPPOSITE. Paired 60 /
        /// baseSeed 1 vs the 62% (set 24%) control:
        ///   both checks   → 50% (set 30%)
        ///   (A) donation  → 52% (set 30%)   ← carries ALL the damage
        ///   (B) Bear only → 62% (set 23%)   ← neutral
        ///
        /// (A) FAILS because its premise is false FOR THESE AGENTS. It rejects
        /// a world where a seat played money to a certain-loss trick while
        /// holding a non-money card — assuming no competent line donates money
        /// with a throwaway available. But PlayoutPolicy and the shortlist shed
        /// by lowest CAPTURE RANK, not lowest VALUE: the $5k is rank 4 and the
        /// $10k rank 8, so they are routinely a seat's lowest legal card and
        /// get shed to lost tricks WHILE the seat still holds higher non-money
        /// cards. (A) reads that normal play as "dominated" and deletes the
        /// TRUE world (the one holding those non-money cards) en masse, biasing
        /// the sample — hence the higher set-rate. This is the inference-side
        /// double-dummy trap made concrete: a "hard" deduction is only hard
        /// relative to a rationality model the POPULATION actually follows, and
        /// "never donate small money" is not how these agents play. (B) is
        /// neutral only because the loose-Bear-on-a-fat-lost-trick event is
        /// rare and mostly honored. Lever + golden locks kept; the salvageable
        /// variant is a RANK-AWARE donation check — reject only when a strictly
        /// LOWER-capture-rank non-money card was legal (matching the agents'
        /// lowest-rank shedding) — but its expected value looks low.
        var filterDominatedDonation: Bool = false
        var filterBearDecline: Bool = false
        /// Master switch read by the trick-play world loop: rejection sampling
        /// runs iff at least one consistency check is enabled.
        var playConsistencyFilter: Bool { filterDominatedDonation || filterBearDecline }
        /// SOFT world-INFERENCE: importance-weight each sampled world by how
        /// plausible the public trick history looks in that world under a small
        /// set of high-confidence card-reading cues. This is the softer
        /// successor to play-consistency rejection: a strange hidden-seat play
        /// nudges the world down instead of deleting it, so we get human-like
        /// "they probably did that because of their cards" inference without
        /// the brittle rationality trap that made the hard donation filter
        /// over-prune true worlds. 0 = off.
        ///
        /// PARKED AT 0 (June 2026): the first 0.45 probe measured below the
        /// same-seed control (57% control → 52% treatment over 60 matches).
        /// The hook is kept because the direction is strategically right, but
        /// the likelihood shape needs tuning before this belongs on a
        /// player-facing tier.
        var playHistoryWeighting: Double = 0.0
        /// A/B-gated ROLLOUT-policy improvement (algorithm work, not a knob):
        /// when the declarer draws trump in a rollout, lead a commanding high
        /// trump rather than the lowest. Sharper rollouts → better MCTS value
        /// estimates → potentially better moves at every tier. Off by default
        /// until a paired A/B confirms it; promote globally if it helps.
        var rolloutCommandingPull: Bool = false
        /// A/B-gated ROLLOUT-policy improvement: Bull endgame management.
        /// With this on, rollout seats shed the Bull on worthless tricks late
        /// in the hand, and when trapped with BER+BUL as the last two cards
        /// they spend the BULL on the small pot and keep the BEAR for the big
        /// one (a trapped Bear is harmless — a forced Bear lead cancels its
        /// own trick).
        ///
        /// PARKED AT FALSE (June 2026): paired self-play at 60 matches /
        /// baseSeed 1 measured control 63% → treatment 50% (challenger
        /// set-rate 15%→19%) — negative-to-noise, so not promoted. The
        /// UNGATED agent-side fixes (Bull-escape shortlist candidates +
        /// specials rescue) are what cure the observed Bull endplays, and
        /// they work BECAUSE rollouts stay pessimistic: the root candidate
        /// "shed the Bull now" rolls out clean while "hold it" rolls out into
        /// the forced final-trick double, giving MCTS the differential. This
        /// rollout rule as written likely over-fires (any moneyless trick
        /// late, for all four rollout seats), washing out futures where one
        /// more trick lands the Bull on partner's money. Lever + golden tests
        /// kept for a refined version.
        var rolloutSpecialEscape: Bool = false
        /// ROLLOUT-policy improvement (PolicyMiner, June 2026 — the #1 mined
        /// disagreement pattern, stable across both teacher configs): the
        /// rollout declarer pulls trump from the TOP (Tiger included)
        /// instead of leading its LOWEST trump, and with no commanding trump
        /// skips the pull rather than donating the round. The low-pull loop
        /// was the largest source of student-vs-teacher regret (mined
        /// exemplars: monster declarer hands rolling out to −$500k).
        ///
        /// MEASURED (June 2026, paired vs same-seed control, baseSeed 1):
        /// 60 matches control 52% → treatment 58%; CONFIRMED at 100 matches
        /// control 49% → treatment 59% (+10pp, set-rate 28%/28%) — the
        /// largest validated gain since the widow-lock, and the first from
        /// mined evidence rather than intuition (contrast `commandingPull`,
        /// which flattened at N=100). PROMOTED to all tiers: sharper
        /// rollouts lift every consumer of PlayoutPolicy. Kept as a field
        /// so it stays A/B-able (turn it off on one side).
        var rolloutTopPull: Bool = true
        /// A/B-gated ROLLOUT-policy improvement (PolicyMiner, June 2026 —
        /// the #2 mined pattern): with length (≥3 cards) behind a side-suit
        /// boss, the rollout leader DUCKS the first round (lowest card of
        /// the suit, ≤ $5k risk) and cashes the boss later, when opponents'
        /// money is forced to follow. Singleton/doubleton bosses still cash
        /// immediately (calibration: a singleton $40k cashes 100%).
        ///
        /// PARKED AT FALSE (June 2026): the blanket version (duck every time
        /// rules 2/3 would cash with length) measured control 62% →
        /// treatment 52% at paired 60/baseSeed 1 — repeated ducking donates
        /// tempo while voids develop. Refined to VIRGIN suits only (one duck
        /// per suit, the exemplars' actual shape) it recovered to 60% vs 62%
        /// — neutral, and a soft rollout prior isn't promoted on a neutral
        /// read. Mined per-position signal evidently doesn't survive as a
        /// blanket rollout rule here (contrast rolloutTopPull, which did).
        /// Lever + golden locks kept for a future, more conditional variant.
        var rolloutEstablishDuck: Bool = false
        /// A/B-gated ROLLOUT-policy improvement (PolicyMiner, June 2026 —
        /// the top follow-side family in the post-topPull re-mine, and the
        /// resurfaced "second-seat ruff/bank" candidate): when winning a
        /// trick mid-round, bank the lowest-rank UNASSAILABLE money winner —
        /// full information says no yet-to-play seat can legally beat it or
        /// Bear the trick — instead of always winning cheap. Last-to-play
        /// keeps the existing max-money bank (B2).
        ///
        /// PARKED AT FALSE (June 2026): paired 60/baseSeed 1 measured
        /// control 62% → treatment 57% — below the paired control. The
        /// deduction is sound but the TRADE is not: banking spends a future
        /// round-winner for present certainty, while the cheap win keeps the
        /// money card as a SECOND winner that competent rollout futures
        /// realize anyway. The mined signal was inflated by the ε-teacher's
        /// greedy bias (sloppy futures squander held winners) — this pattern
        /// ALIGNED with the bias, unlike topPull (bias-neutral, promoted).
        /// Weigh bias alignment before spending a cycle on a mined pattern.
        var rolloutBankWin: Bool = false
        /// Bypass the heuristic shortlist gate entirely and let MCTS grade
        /// EVERY legal move. The shortlist exists for compute (no longer
        /// binding — worst case ~13 candidates vs 4) and to shield the search
        /// from rollout blind spots; against that, every catastrophic bug
        /// found so far has been a shortlist OMISSION, and full-width search
        /// eliminates that failure class outright.
        ///
        /// MEASURED (June 2026, paired 60 / baseSeed 1): exactly neutral —
        /// control 63% → treatment 63%, set-rates within a point. PROMOTED to
        /// Hard + Extreme on robustness grounds (neutral strength + immunity
        /// to the omission class; their higher sample counts only shrink the
        /// selection-noise risk vs the Normal-profile A/B). Easy/Normal stay
        /// curated: preserves the strength ladder, keeps the default tier
        /// snappy, and keeps arena A/Bs (which run Normal) ~3× faster.
        /// `trickCandidates` is ignored when this is on.
        var searchAllLegalMoves: Bool = false
        /// ALGORITHM lever: replace the default depth-1 PIMC trick search with
        /// single-observer IS-MCTS (`AI/ISMCTS.swift`). PIMC samples a world,
        /// applies each ROOT candidate, then plays the rest greedily with full
        /// knowledge of the hidden cards — strategy fusion (rollouts "peek")
        /// and a weak imagined future-self, both untunable. IS-MCTS builds one
        /// tree over the agent's information set, samples a fresh
        /// determinization per iteration (a move is explored only where it is
        /// legal in that world), and searches opponents'/partner's replies with
        /// availability-count UCB, with PlayoutPolicy finishing the tail past
        /// the frontier. Compute-matched to the PIMC budget so an A/B isolates
        /// the estimator, not the rollout count.
        ///
        /// VALIDATED (June 12 2026). Compute-matched (×1 ≈ 80 iterations) is a
        /// sparse 2-ply tree and reads −9pp — but the gain SCALES with
        /// iterations as MCTS theory predicts. Paired vs the same-build PIMC
        /// control: ×1 48% → ×2 52% → ×4 58% (control 57%, N=60), CONFIRMED at
        /// N=100: ×4 58% vs a clean 50% control (set-rate: opponents 35% set vs
        /// the agent's 27%) — +8pp, the first gain from a better ESTIMATOR
        /// rather than better worlds/rollouts, and the structural fix the
        /// double-dummy / inference-trap findings pointed to (it removes PIMC's
        /// strategy fusion WITHOUT assuming an opponent-rationality model). Cost
        /// is the catch: it needs ~300+ iterations, so it belongs on the
        /// compute-tolerant tiers, not the snappy default. See
        /// `ismctsBudgetMultiplier` and the A/B `testSelfPlayISMCTS*`.
        ///
        /// BUT it did NOT replicate on the EXTREME profile (June 12 2026):
        /// extreme+IS-MCTS ×2 (528 iters) = 68% vs a 67% extreme-vs-extreme
        /// control (N=60; the seat/seed confound inflates both) — neutral. The
        /// Normal +8pp was won against a WEAK PIMC; Extreme's full-width search
        /// + deepInference + exact-endgame already close much of the same gap,
        /// so the fusion fix has little headroom left on top. The "wide root
        /// under-budgeting" alternative was TESTED and REJECTED: gating the
        /// IS-MCTS root to the narrow shortlist (`ismctsShortlistRoot`) to
        /// concentrate 528 iters read 40% vs the 67% control — −27pp, because
        /// narrowing reintroduces the shortlist-OMISSION failure class that
        /// `searchAllLegalMoves` exists to kill (and handicaps the root vs a
        /// full-width champion). So the full-legal root is load-bearing on
        /// Extreme and can't be cheaply concentrated; the neutrality is genuine
        /// REDUNDANCY with Extreme's stack, not budget. NET DISPOSITION: NOT
        /// promoted to any player-facing tier — IS-MCTS is a validated research
        /// result (estimator can beat the plateau where PIMC is weak) with no
        /// clean production home (redundant on the strong tiers, too slow for
        /// the snappy Normal default). Kept default-off and A/B-able.
        var useISMCTS: Bool = false
        /// IS-MCTS ONLY: iterations = (samples × max(4, trickCandidates)) × this.
        /// MCTS needs far more iterations than PIMC's focused per-candidate
        /// rollouts to fill its (deep) tree and overcome its higher per-estimate
        /// variance, so the compute-matched (×1) read understates it. This knob
        /// scales the search up to test whether removing strategy fusion
        /// overtakes PIMC's plateau once the tree is adequately sampled.
        var ismctsBudgetMultiplier: Int = 1
        /// IS-MCTS only: gate the ROOT to the narrow heuristic shortlist even
        /// when `searchAllLegalMoves` is on, so the iteration budget
        /// concentrates onto ~trickCandidates root moves (the tree still
        /// searches all legal replies deeper). Tests whether the Extreme-
        /// neutral read was wide-root under-budgeting: a full-legal root (~13
        /// early) spreads 528 iters thin, where the validated Normal regime had
        /// a ≤4-move shortlist at ~80 visits/branch.
        var ismctsShortlistRoot: Bool = false
        /// EXACT ENDGAME — root decisions: when a real decision arrives with
        /// ≤ N tricks remaining (my own hand size), every (world × candidate)
        /// is graded by EndgameSolver — full-information alpha-beta over the
        /// engine's own legal moves — instead of a greedy PlayoutPolicy
        /// rollout. Within a determinized world the endgame is a small
        /// PERFECT-INFORMATION game, so the value is exact: greedy-tail
        /// misevaluations (systematic, so unlike noise they do NOT cancel
        /// between candidates — the Bull/Bear endplay leak was this class)
        /// disappear from late-hand decisions. A skilled human counts the
        /// last tricks exactly; this is that, per sampled world.
        ///
        /// MEASURED (June 2026, 60 matches / baseSeed 1, paired vs the
        /// same-seed control's 62%): gate 4 → 57%, gate 3 → 55%,
        /// gate 2 → 62% with set-rate 24%/24% matching control exactly.
        /// The negative reads at 3–4 are the DOUBLE-DUMMY trap: per-world
        /// minimax assumes perfectly-informed continuation play, which
        /// AMPLIFIES whatever card-location error remains in the sampled
        /// worlds — and at 3–4 tricks out the residual errors are exactly
        /// the decisive ones (who holds the last trump / the Tiger).
        /// Perfect play extracts maximum consequence from wrong guesses;
        /// the greedy rollout's shared blind spots partially cancel between
        /// candidates instead. At gate 2 the worlds are pinned (voids +
        /// counting) and exactness is free. PROMOTED at 2 for Hard +
        /// Extreme on the full-width precedent (neutral strength +
        /// structural immunity to a failure class, here the final-two-trick
        /// forced endplays); Easy/Normal stay 0 for the strength ladder and
        /// to keep the Normal-profile arena baseline comparable across
        /// sessions. Gates ≥3 stay PARKED until the sampled worlds get
        /// sharper (play-consistency filtering is the named candidate) —
        /// exact play amplifies world quality, in both directions.
        var exactEndgameTricks: Int = 0
        /// EXACT ENDGAME — rollout tails (A/B lever): mid-hand rollouts
        /// hand off to the same solver once the side to act holds ≤ N
        /// cards, so root candidates at tricks 7–10 are graded by futures
        /// whose endgames are played perfectly rather than greedily.
        /// Strictly costlier than the root lever (every rollout pays a
        /// solve), so it is measured separately. 0 = off.
        ///
        /// PARKED AT 0 (June 2026): paired 60 / baseSeed 1 at gate 2
        /// measured control 62% → treatment 55% (challenger set-rate
        /// 24%→28%) — below the paired control. The hoped-for upside (exact
        /// tails keep TRUE forced-trap differentials while removing false
        /// ones the greedy tail overstates) is outweighed by double-dummy
        /// amplification, and unlike the root lever there is NO gate small
        /// enough to escape it: the world error a tail solve amplifies is
        /// the one sampled at the MID-HAND root decision (tricks 7–10,
        /// maximal hidden information), regardless of how late the solve
        /// itself fires. The root lever at gate 2 is neutral-and-promoted
        /// precisely because its worlds are sampled late, when voids +
        /// counting have pinned them. Lever + probe test kept; re-judge
        /// only after world sampling itself gets sharper (play-consistency
        /// filtering).
        var rolloutExactTricks: Int = 0
        /// Match-aware trick-play OBJECTIVE: utility = teamNet ($) +
        /// weight × P(win match | final scores). 0 = pure team net (off).
        /// P is a logistic in the score difference (scale $300k) with hard
        /// 0/1 at the $1M finish line (both-cross resolved bid-team-wins, as
        /// the standard endgame rule does). The blend keeps a gradient
        /// everywhere: in a lopsided match P is flat and dollars decide; on a
        /// knife edge (set/made swinging the lead, someone near $1M) the P
        /// term dominates and the agent plays the MATCH, not the hand.
        /// Weight is in dollars per unit of win-probability; ~$400k makes a
        /// decisive match swing outweigh any single-hand money difference.
        ///
        /// VALIDATED + PROMOTED to Normal/Hard/Extreme at 400k (June 13 2026;
        /// Easy stays 0 = relaxed). The all-phases 60-match probe read neutral
        /// (63%→63%) — but that was a POWER problem, not a dead lever: match
        /// context is live in only a few hands of a from-scratch match. The
        /// CONDITIONAL INSTRUMENT (`AIArena.runSelfPlay` `chalStart`/`champStart`
        /// seed every match near the finish — `testSelfPlayMatchObjective*`)
        /// exposed a clear effect. Tied near-finish ($750k each, 120 matches):
        /// dose-response 0→49% / 200k→52% / 400k→55% / 700k→57%. AHEAD (875/625):
        /// 84%→89% with the leader's set-rate 17%→9% (it PROTECTS the lead).
        /// BEHIND (625/875): 21%→25% (it PUSHES). And the from-scratch all-phases
        /// re-check on current code stayed NEUTRAL (53%→53%) — so the lever is
        /// SELF-GATING (the logistic P is flat far from the line → inert
        /// early-match, no over-conservatism) and pure upside in the hands that
        /// decide matches. Free at runtime (one logistic per leaf). 400k is the
        /// fully-validated weight (neutral all-phases + endgame-positive); 700k
        /// read better in the tied race but is unconfirmed all-phases — bump
        /// only after a from-scratch re-check. LESSON: a "neutral" all-phases
        /// read can hide a real effect that only a CONDITIONAL instrument (seed
        /// the live-context state) can see — build the instrument before parking.
        var matchWinWeight: Double = 0
        /// EVALUATOR refit: use HandEvaluator's `.calibrated` tables —
        /// keepProbability / offSuitWinProbability / partnerSupport / widowEV
        /// fitted to the per-card realization rates measured by
        /// `AIArena.runCardCalibration` (June 2026) — instead of the original
        /// hand-set constants. Affects bidding, widow discard, and trump
        /// naming.
        ///
        /// MEASURED (June 2026, paired 60 / baseSeed 1): win-rate exactly
        /// neutral (control 60% → treatment 60%) while taking 60% of the
        /// contracts (vs 52%) at cheaper average contracts ($210k vs $219k)
        /// and a set-rate equal to the opponent's (26%/26%). PROMOTED to all
        /// tiers on correctness grounds (the full-width-search precedent):
        /// the per-card harvest verified the tables unbiased component-by-
        /// component (gross $233k obs / $237k pred at a fresh seed vs
        /// $240k/$217k under the original), and the bid frame reads +$4k.
        /// Honest valuation costs nothing and every future tuning pass
        /// starts from an unbiased base. Kept as a field so it stays
        /// A/B-able (turn it off on one side).
        var calibratedValuation: Bool = true

        /// The HandEvaluator constant set this profile plays with.
        var evaluatorTables: HandEvaluator.Tables {
            calibratedValuation ? .calibrated : .original
        }

        /// DISTRIBUTION-AWARE BIDDING. The scalar bidder declares on the MEAN
        /// (`expectedGross` vs a ceiling), but a set costs the whole contract —
        /// so what matters is the DISTRIBUTION of what you'd capture, not its
        /// mean. When on, `decideBid` replaces `expectedGross` with a rollout
        /// estimate: sample full deals from the auction, play each out with me
        /// declaring, collect the captured-gross distribution, and use the
        /// `bidMakeProbability` quantile — "the contract I make at least p of the
        /// time" — as the decision figure. Prices set risk directly; reuses the
        /// determinize + engine + PlayoutPolicy machinery (the bidder leads, so
        /// setup — name trump, cheapest legal discard — runs through the engine).
        ///
        /// VALIDATED + PROMOTED to Normal + Hard + Extreme (June 13 2026,
        /// p=0.45). Paired
        /// vs the same-seed scalar control: a make-probability sweep at N=60
        /// (control 57%) read p=0.45 → 62% (bid-share 49% = control, set
        /// 30%→23%), 0.55 → 55%, 0.6 → 53%, 0.75 → 47% — a clean dose-response
        /// (over-conservative bidding loses). CONFIRMED at N=100: p=0.45 → 58%
        /// vs a clean 50% control, set 22% vs the scalar champion's 33%. The
        /// mechanism: SAME bid volume, BETTER selection — it declares the
        /// makeable contracts and skips the traps (champion overbids to $234k
        /// and gets set). Unlike IS-MCTS this is ORTHOGONAL to trick-play
        /// strength (the bid decision doesn't touch full-width / deepInference /
        /// exact-endgame), so it transfers across tiers. On Normal+Hard+Extreme
        /// for player difficulty — a competent bidder doesn't gift a human
        /// contracts by overbidding into sets (the scalar champion sets 33%);
        /// EASY stays scalar so its overbidding keeps it gentle/beatable for
        /// newcomers. (Arena A/Bs that run Normal now include the bidder on both
        /// sides — symmetric and still valid, but ~15-20% slower, and the
        /// pre-bidder numbers in older test comments no longer apply; set
        /// rolloutBidEval=false on both sides to isolate a non-bidding lever.)
        /// NOTE: greedy rollouts under-play the
        /// declarer (pessimistic distribution), which is why the calibrated
        /// sweet spot is p=0.45, not the 0.85 the make-rate target would suggest.
        var rolloutBidEval: Bool = false
        /// Deals sampled per bid decision when `rolloutBidEval` is on.
        var bidRolloutWorlds: Int = 24
        /// The make-probability quantile the rollout bidder bids to: the
        /// decision figure is the contract captured in ≥ this fraction of
        /// sampled worlds. Lower = more aggressive. 0.45 is the validated sweet
        /// spot (see `rolloutBidEval`); higher over-conservatively passes +EV
        /// hands and loses win-rate.
        var bidMakeProbability: Double = 0.45
        /// Whether the bid rollout's deal sampling reads the AUCTION (passers
        /// get weak hands, bidders strong ones — same lean as the trick-play
        /// `Determinizer`, strength `bidLeanStrength`). Without it the bid
        /// rollout deals opponents AVERAGE hands even when they've bid up,
        /// making it over-optimistic in CONTESTED auctions — the diagnosed
        /// cause of war over-bids that get set (handlog 7: declarers fighting to
        /// ~$255-265k that their own trick-1 search rated as already lost).
        ///
        /// MEASURED + KEPT ON (June 13 2026, default true on rollout-bid tiers).
        /// Paired 100 / baseSeed 1: control (no-lean vs no-lean) 55% set 28/34
        /// → treatment (lean vs no-lean) 57%, bid-share 52%→48% (more SELECTIVE)
        /// and set-rate 25% vs the no-lean champion's 33%. Win-rate neutral-to-
        /// +2pp in symmetric self-play; the real payoff is vs a HUMAN pushing
        /// the auction (where the handlog over-bids happened). A/B
        /// `testSelfPlayBidLean`; statistical locks in `BidEvalTests`.
        var bidRolloutLean: Bool = true
        /// When the rollout bidder is on, DON'T multiply its ceiling by
        /// `bidAggression`: the rollout figure (a make-probability quantile)
        /// already prices set risk, so a 1.05 stretch commits above the agent's
        /// own safe level and over-bids contested auctions (handlog 7/8). Only
        /// matters on tiers with bidAggression != 1.0 (Hard/Extreme = 1.05);
        /// no-op on Normal (1.00). MEASURED + KEPT ON (June 13 2026): on a
        /// Normal+1.05 proxy, paired 100/baseSeed 1, control (1.05 both) 50% set
        /// 35% → drop-vs-1.05 51%, bid-share 55%→46% (more selective), set-rate
        /// 28% vs 31% — win-rate neutral, fewer contested over-bids. A/B
        /// `testSelfPlayBidAggressionDrop`.
        var bidRolloutDropAggression: Bool = true

        // ── Selectable strength tiers (Settings → Opponents) ───────────────
        // The strength ladder is driven, in order, by: `samples` (search
        // depth), `trickCandidates` (shortlist width) and `bidLeanStrength`
        // (auction reading) — NOT by bid aggression, which self-play shows is
        // ~win-rate-neutral (it's flavor, not strength). `blunderRate` injects
        // only believable, BOUNDED mistakes (see `decideTrickPlay`) for the
        // lower tiers; relying on it for difficulty feels random, not weak.

        /// `Easy` — shallow search, narrow shortlist, ignores the auction, and
        /// slips up now and then. Beatable, not erratic.
        static let easy    = Difficulty(samples: 8,  blunderRate: 0.15,
                                        bidAggression: 0.85, partnerRespect: 0.95,
                                        matchAwareness: 0.5, trickCandidates: 3,
                                        bidLeanStrength: 0.0)
        /// `Normal` — a solid club player. Reads the auction and bids what it
        /// can MAKE (distribution-aware: rolls out P(make) — the +8pp/N=100
        /// lever was validated on exactly this profile), so it stops gifting a
        /// human contracts by overbidding into sets. Trick-play depth stays
        /// modest (shortlist gate, no deep inference / exact-endgame), so a
        /// skilled player still beats it on PLAY.
        static let normal  = Difficulty(samples: 20, blunderRate: 0.06,
                                        bidAggression: 1.00, partnerRespect: 0.78,
                                        matchAwareness: 1.0, trickCandidates: 4,
                                        bidLeanStrength: 1.0,
                                        matchWinWeight: 400_000,
                                        rolloutBidEval: true)
        /// `Hard` — deeper search over EVERY legal move (no shortlist gate),
        /// strong auction read, no deliberate mistakes, the last two tricks of
        /// every sampled world solved exactly, and distribution-aware bidding
        /// (rolls out P(make) instead of bidding the mean — June 2026).
        static let hard    = Difficulty(samples: 36, blunderRate: 0.0,
                                        bidAggression: 1.05, partnerRespect: 0.68,
                                        matchAwareness: 1.0, trickCandidates: 5,
                                        bidLeanStrength: 1.6,
                                        searchAllLegalMoves: true,
                                        exactEndgameTricks: 2,
                                        matchWinWeight: 400_000,
                                        rolloutBidEval: true)
        /// `Extreme` — RIGHT-SIZED (June 2026). Paired self-play showed neither
        /// extra samples (60 vs 36) nor pushier bid knobs (bidLean 2.0,
        /// respect 0.60) beat Hard — the MCTS search has plateaued at Hard's
        /// settings, and the unvalidated bid knobs added drag. So Extreme is now
        /// Hard's VALIDATED bidding + the count-exhaustion card-counting
        /// deduction + a small search bump (samples 44, shortlist 6) + the
        /// exact two-trick endgame solve. Genuine additional strength needs
        /// ALGORITHM work (PlayoutPolicy / world-sampling quality — the
        /// high-leverage levers), not more compute.
        static let extreme = Difficulty(samples: 44, blunderRate: 0.0,
                                        bidAggression: 1.05, partnerRespect: 0.68,
                                        matchAwareness: 1.0, trickCandidates: 6,
                                        bidLeanStrength: 1.6,
                                        deepInference: true,
                                        searchAllLegalMoves: true,
                                        exactEndgameTricks: 2,
                                        matchWinWeight: 400_000,
                                        rolloutBidEval: true)

        /// Player-facing strength tiers. A small, Codable, ordered enum so the
        /// settings layer and UI deal in names, not tuning constants.
        nonisolated enum Level: String, Codable, CaseIterable, Identifiable, Sendable {
            case easy, normal, hard, extreme

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .easy:    return "Easy"
                case .normal:  return "Normal"
                case .hard:    return "Hard"
                case .extreme: return "Extreme"
                }
            }

            /// One-line description for the settings footer.
            var blurb: String {
                switch self {
                case .easy:    return "Relaxed. Thinks shallowly, ignores the bidding, and slips up now and then."
                case .normal:  return "A solid club player. Bids honestly and reads the auction. The default."
                case .hard:    return "Searches deeper — every legal card is considered — and reads the bidding closely."
                case .extreme: return "Maximum search, full card-counting deduction, and every legal card considered."
                }
            }

            /// The tuning profile this level plays with.
            var profile: Difficulty {
                switch self {
                case .easy:    return .easy
                case .normal:  return .normal
                case .hard:    return .hard
                case .extreme: return .extreme
                }
            }
        }
    }

    let name: String
    let difficulty: Difficulty
    private let seedBox: RNGBox

    init(name: String = "AI",
         difficulty: Difficulty = .normal,
         seed: UInt64) {
        self.name = name
        self.difficulty = difficulty
        self.seedBox = RNGBox(seed: seed)
    }

    // MARK: - PlayerAgent

    func chooseMove(from view: PlayerView) async -> Move {
        let legal = view.legalMoves
        precondition(!legal.isEmpty,
                     "MonteCarloAgent asked to move with no legal moves")
        if legal.count == 1 { return legal[0] }

        switch view.phase {
        case .bidding:         return decideBid(view, legal: legal)
        case .misdealDecision: return decideMisdeal(view, legal: legal)
        case .widowDiscard:    return decideDiscard(view, legal: legal)
        case .namingTrump:     return decideTrump(view, legal: legal)
        case .trickPlay:       return decideTrickPlay(view, legal: legal)
        case .handComplete:    return legal[0]
        }
    }

    // MARK: - Misdeal decision

    /// Agreement-mode misdeal: vote to KEEP the hand (`declineMisdeal`) when it
    /// is worth playing, else agree to the redeal (`callMisdeal`). The redeal is
    /// triggered by ANY seat being money-poor — so a strong hand of ours must
    /// not be thrown away just because someone else is short (the old `legal[0]`
    /// agreed to EVERY redeal, even holding a monster). In automatic mode the
    /// only legal move is the forced redeal, so we return it.
    private func decideMisdeal(_ view: PlayerView, legal: [Move]) -> Move {
        guard legal.contains(.declineMisdeal) else {
            return legal.first ?? .callMisdeal      // automatic mode: forced redeal
        }
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // A hand that values at or above the opening floor is a real declare
        // candidate — keep it. Below that, a fresh deal is the better gamble.
        return valuation.expectedGross >= Bidding.openingMinimum
            ? .declineMisdeal
            : .callMisdeal
    }

    // MARK: - Bidding

    private func decideBid(_ view: PlayerView, legal: [Move]) -> Move {
        // Split legal moves into pass + bids (sorted by amount asc).
        let passMove = legal.first { $0.isPass }
        let bidMoves: [(Move, Int)] = legal.compactMap { m in
            if let amt = m.bidAmount { return (m, amt) }; return nil
        }.sorted { $0.1 < $1.1 }

        // Hand value as if I become declarer with best trump.
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // Distribution-aware bidding (lever): the decision figure becomes the
        // make-probability quantile of rolled-out captured gross — "the contract
        // I make at least p of the time" — instead of the mean `expectedGross`,
        // so set risk is priced directly.
        let decisionGross = difficulty.rolloutBidEval
            ? safeContractEstimate(view: view, fallback: valuation.expectedGross)
            : valuation.expectedGross
        let rawGross = Double(decisionGross)

        // The aggression multiplier is a heuristic stretch over the MEAN
        // (scalar) valuation. The rollout figure already prices set risk (it's
        // a make-probability quantile), so multiplying it by 1.05 just commits
        // ABOVE the agent's own safe level — exactly the war over-bids that get
        // set (handlog 7/8: fighting to a contract its trick-1 search rated as
        // already lost). So drop the multiplier for the rollout bidder.
        let aggressionFactor = (difficulty.rolloutBidEval && difficulty.bidRolloutDropAggression)
            ? 1.0
            : difficulty.bidAggression

        // Match awareness — see below.
        let ceiling = applyMatchAwareness(
            base: rawGross * aggressionFactor,
            view: view)

        var notes: [String] = []
        let partnerHighBidder = {
            if let hb = view.highBidder, hb != view.me,
               Seats.team(of: hb) == Seats.team(of: view.me) { return true }
            return false
        }()

        // The decision itself, captured so we can trace it before returning.
        let move: Move = {
            // ---- Forced opener: pass is not legal, must bid.
            if passMove == nil {
                // Bid the minimum legal amount. Forced openings happen on
                // weak hands; we don't speculate higher than required.
                notes.append("forced opener — bidding the minimum")
                return bidMoves.first?.0 ?? legal[0]
            }

            guard let (cheapestBid, cheapestAmt) = bidMoves.first else {
                return passMove!
            }

            // ---- Partner is current high bidder: defer unless decisively stronger.
            if let hb = view.highBidder, let hbAmount = view.highBid,
               Seats.team(of: hb) == Seats.team(of: view.me), hb != view.me {
                // Once BOTH opponents have passed, the contract is the team's to
                // keep no matter who declares — raising our own partner only
                // inflates the contract (and the set-back risk) for zero gain.
                // Suppress the override. Exception: a partner sitting on the
                // forced minimum open ($175k) may be a weak/forced opener (they
                // didn't choose to bid that high), so allow a single rescue.
                let opponentsLive = Seats.all.contains {
                    Seats.team(of: $0) != Seats.team(of: view.me)
                        && !view.passed.contains($0)
                }
                if !opponentsLive && hbAmount > Bidding.openingMinimum {
                    notes.append("both opponents passed — not bidding partner up "
                                 + "($\(hbAmount / 1000)k already holds the contract)")
                    return passMove!
                }
                // Override threshold scales with partnerRespect.
                // respect 1.0 → need rawGross >= hbAmount + $80k
                // respect 0.0 → need rawGross >  hbAmount
                let extraNeeded = Int(80_000.0 * difficulty.partnerRespect)
                let threshold = hbAmount + extraNeeded
                notes.append("partner holds the bid ($\(hbAmount / 1000)k); "
                             + "override needs valuation > $\(threshold / 1000)k")
                if decisionGross > threshold
                    && Double(cheapestAmt) <= ceiling {
                    return cheapestBid
                }
                return passMove!
            }

            // ---- Opponent or no one has high bid: bid the minimum legal raise
            // that fits the ceiling, otherwise pass. Strong players don't bid
            // themselves up.
            if Double(cheapestAmt) <= ceiling {
                // Optional jump-bid on monster hands: if my estimate is FAR
                // above the cheapest legal bid (≥ 1.5× the cheapest), and
                // aggression is high, step up one tier to telegraph strength
                // to partner. Most of the time we still bid the minimum.
                if difficulty.bidAggression >= 0.85
                    && rawGross >= Double(cheapestAmt) * 1.50
                    && bidMoves.count >= 2
                    && Double(bidMoves[1].1) <= ceiling
                    && shouldJumpBid() {
                    notes.append("jump-bid: valuation ≥ 1.5× the minimum raise")
                    return bidMoves[1].0
                }
                return cheapestBid
            }
            notes.append("cheapest legal bid $\(cheapestAmt / 1000)k exceeds ceiling — pass")
            return passMove!
        }()

        if AIDecisionTrace.shared.isEnabled {
            if partnerHighBidder && notes.isEmpty {
                notes.append("partner holds the bid")
            }
            let chosenText = move.isPass
                ? "pass"
                : move.bidAmount.map { "$\($0 / 1000)k" } ?? "?"
            if difficulty.rolloutBidEval {
                notes.append("rollout bid: P(make)=\(Int(difficulty.bidMakeProbability * 100))% "
                             + "contract $\(decisionGross / 1000)k "
                             + "(mean valuation $\(valuation.expectedGross / 1000)k)")
            }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: chosenText,
                valuationGross: decisionGross,
                ceiling: Int(ceiling), notes: notes))
        }

        return move
    }

    /// Tighten the ceiling when our team is near the $1M finish line;
    /// loosen it when we're far behind and opponents are near it.
    /// Returns the adjusted ceiling.
    private func applyMatchAwareness(base: Double, view: PlayerView) -> Double {
        guard difficulty.matchAwareness > 0 else { return base }
        let myTeam = Seats.team(of: view.me)
        let mine = Double(view.matchScore[myTeam] ?? 0)
        let theirs = Double(view.matchScore[1 - myTeam] ?? 0)
        // Conservative if we're close to winning.
        if mine >= 750_000 {
            let progress = min(1.0, (mine - 750_000) / 250_000)
            let shrink = 0.30 * progress * difficulty.matchAwareness
            return base * (1.0 - shrink)
        }
        // Aggressive if we're well behind AND they're approaching the goal.
        if theirs >= 700_000 && theirs - mine >= 150_000 {
            let urgency = min(1.0, (theirs - 700_000) / 300_000)
            let stretch = 0.20 * urgency * difficulty.matchAwareness
            return base * (1.0 + stretch)
        }
        return base
    }

    private func shouldJumpBid() -> Bool {
        // 35% chance, so jump bids are an occasional flavour, not standard.
        seedBox.nextInt(upperBound: 100) < 35
    }

    // MARK: - Distribution-aware bid evaluation (rolloutBidEval)

    /// The make-probability quantile of the captured-gross distribution if I
    /// declared this hand: sample `bidRolloutWorlds` full deals from the
    /// auction, play each out with me declaring, and return the contract level
    /// I capture in at least `bidMakeProbability` of them. Falls back to the
    /// scalar `expectedGross` if no rollout completed.
    private func safeContractEstimate(view: PlayerView, fallback: Int) -> Int {
        let worlds = max(1, difficulty.bidRolloutWorlds)
        var grosses: [Int] = []
        grosses.reserveCapacity(worlds)
        for w in 0..<worlds {
            if let g = rolloutDeclareGross(view: view,
                                           seed: seedBox.nextRaw() &+ UInt64(w)) {
                grosses.append(g)
            }
        }
        guard !grosses.isEmpty else { return fallback }
        grosses.sort()
        // safeContract = the value X with P(captured >= X) ≈ p. With grosses
        // sorted ascending, the element at rank floor((1-p)·n) has a ≥ p tail
        // at or above it.
        let p = min(0.95, max(0.05, difficulty.bidMakeProbability))
        let idx = Int((1.0 - p) * Double(grosses.count))
        return grosses[max(0, min(grosses.count - 1, idx))]
    }

    /// One bid-time rollout: sample the hidden hands + widow, set me up as the
    /// declarer (name trump with the real heuristic, discard the cheapest legal
    /// three), play the hand out greedily, and return my team's captured gross.
    /// The contract amount doesn't affect play, so a placeholder bid is fine.
    private func rolloutDeclareGross(view: PlayerView, seed: UInt64) -> Int? {
        guard let deal = sampleBidDeal(view: view, seed: seed) else { return nil }
        var hands = deal.hands
        hands[view.me] = view.myHand + deal.widow          // the bidder takes the 16
        var s = GameState(
            dealSeed: 0, dealer: PlayerID(0),
            hands: hands, widow: [],
            phase: .namingTrump, toAct: view.me,
            highBid: Bidding.openingMinimum, highBidder: view.me,
            passed: Set(Seats.all.filter { $0 != view.me }),
            bidHistory: [], trump: nil, discardAnnouncement: nil,
            misdealRule: .disabled, endgameRule: .standard,
            houseRules: view.houseRules,
            currentTrick: nil, completedTricks: [], capturedByTeam: [0: [], 1: []],
            matchScore: view.matchScore, dealtHands: [:], dealtWidow: [])

        let trumpMove = decideTrump(s.view(for: view.me),
                                    legal: s.legalMoves(for: view.me))
        guard let s1 = try? s.applying(trumpMove, by: view.me) else { return nil }
        s = s1
        let discardLegal = s.legalMoves(for: view.me)
        let discardMove = discardLegal.min {
            discardCost($0.discardCards ?? []) < discardCost($1.discardCards ?? [])
        } ?? discardLegal.first
        guard let dm = discardMove, let s2 = try? s.applying(dm, by: view.me) else {
            return nil
        }
        s = s2

        var steps = 0
        while s.phase != .handComplete && steps < 600 {
            let mv = PlayoutPolicy.move(in: s, seat: s.toAct,
                                        commandingPull: difficulty.rolloutCommandingPull,
                                        specialEscape: difficulty.rolloutSpecialEscape,
                                        topPull: difficulty.rolloutTopPull,
                                        establishDuck: difficulty.rolloutEstablishDuck,
                                        bankWin: difficulty.rolloutBankWin)
            guard let ns = try? s.applying(mv, by: s.toAct) else { break }
            s = ns
            steps += 1
        }
        let myTeam = Seats.team(of: view.me)
        return (s.capturedByTeam[myTeam] ?? []).reduce(0) { $0 + GameState.trickValue($1) }
    }

    /// Sample the 3 hidden hands + 3 widow cards from the deck minus my known
    /// hand. With `bidRolloutLean` the 39 dealt cards are biased by the AUCTION
    /// (strong cards drift to seats that bid, weak to passers) so a contested
    /// auction makes opponents as strong as their bidding implies; the 3 widow
    /// cards are reserved at random first (the widow is independent of the
    /// auction). Uniform when the lean is off or `bidLeanStrength == 0`.
    /// Internal so the lean is statistically testable. nil only on a deck
    /// bookkeeping mismatch (e.g. called outside bidding) — never in practice.
    func sampleBidDeal(view: PlayerView,
                       seed: UInt64) -> (hands: [PlayerID: [Card]], widow: [Card])? {
        let mine = Set(view.myHand)
        var pool = Deck.full.filter { !mine.contains($0) }
        guard pool.count == 13 * (Seats.count - 1) + 3 else { return nil }   // 42
        var rng = SeededRNG(seed: seed)
        func shuffle(_ a: inout [Card]) {
            for i in stride(from: a.count - 1, to: 0, by: -1) {
                a.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
        }
        shuffle(&pool)
        let others = Seats.all.filter { $0 != view.me }

        // The widow is 3 random cards, dealt independently of the bidding.
        let widow = Array(pool.suffix(3))
        let deal = Array(pool.prefix(pool.count - 3))     // 39 to distribute

        var hands: [PlayerID: [Card]] = [view.me: view.myHand]
        for s in others { hands[s] = [] }

        if difficulty.bidRolloutLean && difficulty.bidLeanStrength > 0 {
            let lean = bidLeanBySeat(view: view)
            for card in deal {
                let need = others.filter { (hands[$0]?.count ?? 0) < 13 }
                let pick = weightedSeat(need, card: card, lean: lean,
                                        strength: difficulty.bidLeanStrength, rng: &rng)
                hands[pick, default: []].append(card)
            }
        } else {
            var cursor = 0
            for s in others { hands[s] = Array(deal[cursor ..< cursor + 13]); cursor += 13 }
        }
        return (hands, widow)
    }

    /// Per hidden seat: + if they have bid (scaled by amount), − if they
    /// passed, 0 if not yet acted. Mirrors `Determinizer.computeLean` for the
    /// bid-time sampler (no trump is named yet, so it's strength-only).
    private func bidLeanBySeat(view: PlayerView) -> [PlayerID: Double] {
        var highestBid: [PlayerID: Int] = [:]
        for rec in view.bidHistory {
            if case .bid(let amt) = rec.action {
                highestBid[rec.player] = max(highestBid[rec.player] ?? 0, amt)
            }
        }
        var lean: [PlayerID: Double] = [:]
        for s in Seats.all where s != view.me {
            if let amt = highestBid[s] {
                lean[s] = min(2.0, 0.5 + Double(amt - Bidding.openingMinimum) / 75_000.0)
            } else if view.passed.contains(s) {
                lean[s] = -1.0
            } else {
                lean[s] = 0.0
            }
        }
        return lean
    }

    /// Pick a seat for `card`, weighted by exp(strength · centredValue · lean):
    /// >1 when a strong card meets a bidder (or a weak card a passer). Among the
    /// seats that still need cards, so counts stay exact.
    private func weightedSeat(_ seats: [PlayerID], card: Card,
                              lean: [PlayerID: Double], strength: Double,
                              rng: inout SeededRNG) -> PlayerID {
        guard seats.count > 1 else { return seats.first ?? PlayerID(0) }
        let v = bidCardValue(card) - 0.5
        let weights = seats.map { exp(strength * v * (lean[$0] ?? 0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return seats[0] }
        let r = Double(rng.next() % 1_000_000) / 1_000_000.0 * total
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if r <= acc { return seats[i] }
        }
        return seats[seats.count - 1]
    }

    /// 0…1 "how good to hold" — money and high rank are strong, specials high.
    /// No trump bonus (trump isn't named at bid time). Mirrors
    /// `Determinizer.cardValueScore`.
    private func bidCardValue(_ c: Card) -> Double {
        switch c {
        case .tiger: return 1.0
        case .bull, .bear: return 0.5
        case .colored(_, let r):
            var s = Double(r.rawValue) / 12.0 * 0.5
            s += Double(r.moneyValue) / 40_000.0 * 0.4
            return min(1.0, s)
        }
    }

    // MARK: - Widow discard (trump already known)

    private func decideDiscard(_ view: PlayerView, legal: [Move]) -> Move {
        // Trump was named in the previous phase — score each legal discard
        // against the known trump rather than searching jointly.
        guard let trump = view.trump else { return legal[0] }

        let discards = legal.compactMap { m -> (Move, [Card])? in
            if let cs = m.discardCards { return (m, cs) }; return nil
        }
        guard !discards.isEmpty else { return legal[0] }

        // Shortlist by ascending cost: the engine already enforces the
        // protection ordering (specials, trump, money), so cheap = low-rank
        // off-color trash, which is exactly the right thing to throw away.
        let ranked = discards
            .map { ($0.0, $0.1, discardCost($0.1)) }
            .sorted { $0.2 < $1.2 }
            .prefix(max(8, difficulty.trickCandidates * 2))

        var best: (Move, Int) = (legal[0], Int.min)
        for (move, cards, _) in ranked {
            var hand = view.myHand
            for c in cards { if let i = hand.firstIndex(of: c) { hand.remove(at: i) } }
            let score = HandEvaluator.evaluate(view: view, hand: hand, assumingTrump: trump,
                                               tables: difficulty.evaluatorTables)
            if score > best.1 { best = (move, score) }
        }
        return best.0
    }

    private func discardCost(_ cards: [Card]) -> Int {
        cards.reduce(0) { acc, c in
            acc + c.moneyValue * 1_000 + cardRank(c)
        }
    }

    // MARK: - Naming trump

    private func decideTrump(_ view: PlayerView, legal: [Move]) -> Move {
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // Find the .nameTrump move corresponding to bestTrump.
        for m in legal {
            if case .nameTrump(let c) = m, c == valuation.bestTrump { return m }
        }
        return legal[0]
    }

    // MARK: - Trick play (heuristic shortlist + MCTS)

    private func decideTrickPlay(_ view: PlayerView, legal: [Move]) -> Move {
        let inference = TableInference(view: view,
                                       deepInference: difficulty.deepInference)
        let shortlist = trickShortlist(view: view,
                                       legal: legal,
                                       inference: inference)

        // EXACT-ENDGAME GATE for this decision: rollouts hand off to the
        // solver once the side to act holds ≤ `rolloutExactTricks` cards;
        // when the ROOT decision itself falls inside the `exactEndgameTricks`
        // window the gate rises to my current hand size, so every candidate
        // is solved immediately (no greedy steps at all).
        let exactRootActive = difficulty.exactEndgameTricks > 0
            && view.myHand.count <= difficulty.exactEndgameTricks
        let exactGate = exactRootActive
            ? max(difficulty.rolloutExactTricks, view.myHand.count)
            : difficulty.rolloutExactTricks

        // Table-read shared by both paths, built only when capturing. The
        // legal-vs-shortlist line is what makes an OMISSION visible — when the
        // strongest move never reaches MCTS because the heuristic gate dropped
        // it, this is the only place that shows up.
        let baseNotes: [String] = AIDecisionTrace.shared.isEnabled
            ? (exactRootActive
               ? ["exact endgame: candidates graded by alpha-beta per world, not rollouts"]
               : [])
              + shortlistNote(legal: legal, shortlist: shortlist)
              + tracePlayNotes(view: view, inference: inference)
            : []

        // Singleton shortlist: the heuristic narrowed ≥2 legal moves to one, so
        // MCTS is skipped. Still a real decision — record it (with no scores)
        // so heuristically-forced plays aren't invisible to review.
        if shortlist.count == 1 {
            if AIDecisionTrace.shared.isEnabled, let card = shortlist[0].playedCard {
                AIDecisionTrace.shared.record(.init(
                    seat: view.me, chosen: card, blundered: false,
                    candidates: [],
                    notes: ["forced by shortlist (no MCTS)"] + baseNotes))
            }
            return shortlist[0]
        }

        // MCTS over determinized worlds: for each candidate, sample
        // worlds, apply candidate, rollout via PlayoutPolicy, score by
        // team net.
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        var totals = [Move: Double]()
        var weights = [Move: Double]()
        var counts = [Move: Int]()

        // Per-decision search budget (rollouts). Shared by both estimators so
        // an IS-MCTS A/B isolates the estimator, not the compute.
        let budget = difficulty.samples * max(4, difficulty.trickCandidates)

        // Fresh determinized world with the root player to act — the sampler
        // both estimators draw from (same hard deductions / soft priors).
        func sampledWorld() -> (world: AIWorld, determinizer: Determinizer)? {
            var det = Determinizer(view: view, seed: seedBox.nextRaw(),
                                   bidLeanStrength: difficulty.bidLeanStrength,
                                   deduceWidowHoldings: difficulty.deduceWidowHoldings,
                                   declarerTrumpBias: difficulty.declarerTrumpBias,
                                   filterDominatedDonation: difficulty.filterDominatedDonation,
                                   filterBearDecline: difficulty.filterBearDecline)
            let world = difficulty.playConsistencyFilter
                ? det.sampleConsistent()
                : (det.sample() ?? det.sampleUnconstrained())
            guard let world else { return nil }
            return (world, det)
        }

        func sampleWeightedWorld() -> (state: GameState, weight: Double)? {
            guard let sample = sampledWorld() else { return nil }
            let world = sample.world
            let weight = difficulty.playHistoryWeighting > 0
                ? sample.determinizer.playHistoryWeight(
                    world,
                    strength: difficulty.playHistoryWeighting)
                : 1.0
            return (world.state, weight)
        }

        func sampleWorldState() -> GameState? {
            sampledWorld()?.world.state
        }

        if difficulty.useISMCTS {
            // SINGLE-OBSERVER IS-MCTS: one tree, a fresh determinization per
            // iteration, opponents/partner searched (not assumed greedy-
            // omniscient), PlayoutPolicy finishing past the frontier. Root
            // children map straight onto the same totals/counts the tie-break
            // and trace tail below already consume.
            // Optionally narrow the ROOT to the heuristic shortlist (even under
            // full-width search) so iterations concentrate; the tree still
            // searches all legal replies at deeper nodes.
            let ismctsRoot = difficulty.ismctsShortlistRoot
                ? trickShortlist(view: view, legal: legal,
                                 inference: inference, forceNarrow: true)
                : shortlist
            let stats = ISMCTS.search(
                rootCandidates: ismctsRoot,
                rootTeam: myTeam,
                iterations: budget * max(1, difficulty.ismctsBudgetMultiplier),
                sampleWorld: sampleWorldState,
                leafValue: { evaluateWorld($0, myTeam: myTeam,
                                           baseline: baseline,
                                           exactGate: max(difficulty.rolloutExactTricks,
                                                          difficulty.exactEndgameTricks)) },
                policyMove: { PlayoutPolicy.move(in: $0, seat: $0.toAct,
                                                 commandingPull: difficulty.rolloutCommandingPull,
                                                 specialEscape: difficulty.rolloutSpecialEscape,
                                                 topPull: difficulty.rolloutTopPull,
                                                 establishDuck: difficulty.rolloutEstablishDuck,
                                                 bankWin: difficulty.rolloutBankWin) },
                nextRandom: { seedBox.nextRaw() })
            for st in stats where st.visits > 0 {
                totals[st.move] = st.total
                counts[st.move] = st.visits
            }
        } else {
            // DEPTH-1 PIMC with ROLLOUT-BUDGET REALLOCATION: every sampled
            // world is reused for every candidate, so a 13-candidate decision
            // spends 13× the rollouts of a 2-candidate one — yet narrow
            // decisions are where variance bites hardest ("R$5 or R$40 under a
            // loose Tiger" hinges on one hidden card, and produced opposite
            // $80k+ preferences on back-to-back identical deals). Hold the
            // rollout budget roughly constant instead: few candidates →
            // proportionally more sampled worlds, capped at 4× base; wide
            // decisions keep the base sample count.
            let worldCount = min(difficulty.samples * 4,
                                 max(difficulty.samples, budget / max(1, shortlist.count)))
            for _ in 0..<worldCount {
                guard let world = sampleWeightedWorld() else { continue }
                for cand in shortlist {
                    guard let afterMine = try? world.state.applying(cand, by: view.me)
                    else { continue }
                    let u = evaluateWorld(afterMine, myTeam: myTeam,
                                          baseline: baseline, exactGate: exactGate)
                    totals[cand, default: 0] += world.weight * u
                    weights[cand, default: 0] += world.weight
                    counts[cand, default: 0] += 1
                }
            }
        }

        let scored = shortlist
            .filter { (weights[$0] ?? Double(counts[$0] ?? 0)) > 0 }
            .map { move -> (Move, Double) in
                let denom = weights[move] ?? Double(counts[move] ?? 1)
                return (move, totals[move]! / denom)
            }
            .sorted { $0.1 > $1.1 }

        guard let topMean = scored.first?.1 else { return shortlist[0] }

        // Near-tie tiebreak: when candidates score within MCTS noise of the
        // best, the dollars printed on the card and the conservation rules
        // decide — those are CERTAIN, a sub-noise difference in rollout means
        // is not. Ordering (see `tiePreference`): never spend specials on a
        // tie, then feed an opponent-bound trick as LITTLE money as possible
        // (or a safely-partner-bound trick as MUCH as possible), then
        // conserve trump, then lowest rank. Full-width search made the money
        // term necessary: dominated money-donations now reach MCTS, and a
        // money-blind tie once donated the G$40 over the G$5 in real play.
        // Is MY TEAM safely taking this trick (I win it, OR a partner does and
        // it can't be overturned)? Then a near-tie should BANK the most money;
        // otherwise (donating to an opponent, or leading into exposure) it
        // commits the least. The old form only counted a partner's win, so the
        // agent under-banked the trick it was taking ITSELF (handlog 8: played
        // Y$30 over Y$40 / Y$15 over Y$30 on its own winners).
        let bankToOwnTeam: Bool = {
            guard let trump = view.trump,
                  let trick = view.currentTrick, !trick.plays.isEmpty
            else { return false }
            let winner = GameState.trickWinner(trick, trump: trump)
            guard Seats.team(of: winner) == Seats.team(of: view.me) else { return false }
            return trick.plays.count == Seats.count - 1
                || !canBeOverturned(trick: trick, onTable: trick.plays,
                                    trump: trump, inference: inference,
                                    view: view)
        }()
        // TIE WINDOW: candidates within this much mean-net of the best are
        // "ties," decided by the certain dollars (`tiePreference`) rather than
        // a sub-noise difference in rollout means. A flat $20k is deliberate and
        // WELL-CALIBRATED: a NOISE-SCALED window (size it to the paired standard
        // error, trusting the search more when it's confident) was built and
        // A/B'd (handlog 8 T6 motivation) and read NEUTRAL-to-−5pp vs this flat
        // value (100 / baseSeed 1: 53% flat → 48% noise-scaled) — sub-$20k mean
        // gaps really are mostly noise, and the conservation tiebreak beats them.
        // So the flat window stays; see `tiePreference` for the (separate, kept)
        // money-direction fix.
        let tieEps = 20_000.0
        let best = scored
            .filter { $0.1 >= topMean - tieEps }
            .min {
                guard let trump = view.trump,
                      let a = $0.0.playedCard, let b = $1.0.playedCard
                else { return false }
                return Self.tiePreference(a, trump: trump, bankToOwnTeam: bankToOwnTeam)
                     < Self.tiePreference(b, trump: trump, bankToOwnTeam: bankToOwnTeam)
            }
            ?? scored[0]

        var blundered = false
        var chosen = best.0
        if shouldBlunder(), scored.count > 1 {
            // Believable AND bounded: blunder only among non-best moves that cost
            // no more than `blunderMaxRegret` vs the best, so an "easy" mistake is
            // a slightly-wrong card, never a catastrophic giveaway (e.g. feeding
            // the $40k). Picking the strictly worst card was the old behaviour.
            let blunderMaxRegret = 60_000.0   // TUNE
            let candidates = scored.filter {
                $0.0 != best.0 && topMean - $0.1 <= blunderMaxRegret
            }
            if !candidates.isEmpty {
                chosen = candidates[intRand(candidates.count)].0
                blundered = true
            }
        }

        // Debug capture (off in normal play and self-play): record the scored
        // shortlist and the table-read that picked the branch, so a reviewer
        // can see WHY this move beat the alternatives.
        if AIDecisionTrace.shared.isEnabled, let card = chosen.playedCard {
            let cands = scored.compactMap { mv, mean -> AIDecisionTrace.Candidate? in
                guard let c = mv.playedCard else { return nil }
                return .init(card: c, meanNet: mean, samples: counts[mv] ?? 0)
            }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: card, blundered: blundered,
                candidates: cands,
                notes: baseNotes))
        }

        return chosen
    }

    /// One trace line showing the full legal play set and what survived the
    /// heuristic shortlist gate. Makes omission failures (the right move never
    /// reaching MCTS) legible. Built only when capture is on.
    private func shortlistNote(legal: [Move], shortlist: [Move]) -> [String] {
        let legalCards = legal.compactMap { $0.playedCard }
        let shortCards = shortlist.compactMap { $0.playedCard }
        guard !legalCards.isEmpty else { return [] }
        return ["legal \(legalCards.count): \(legalCards.map(HandLog.token).joined(separator: " "))"
                + "  →  shortlisted \(shortCards.count): "
                + shortCards.map(HandLog.token).joined(separator: " ")]
    }

    /// A compact, human-readable table-read for the decision trace. Mirrors
    /// the signals the shortlist branches actually key on — partner control,
    /// whether the partner-dump was treated as contestable (the exact flag
    /// behind "should I overtake my own partner?"), loose specials, and the
    /// highest card still out in the relevant colors. Built only when the
    /// trace is enabled.
    private func tracePlayNotes(view: PlayerView,
                                inference: TableInference) -> [String] {
        guard let trump = view.trump else { return [] }
        var n: [String] = []
        n.append("tigerOut=\(inference.isTigerOut)"
                 + " trumpOut=\(inference.trumpStillOutInOpponentsAndPartner)"
                 + " bullOut=\(inference.isBullOut) bearOut=\(inference.isBearOut)")

        guard let trick = view.currentTrick, !trick.plays.isEmpty else {
            n.append("leading; amDeclarer=\(view.me == view.highBidder)")
            if let hi = inference.highestOutInColor(trump) {
                n.append("highest trump still out: \(HandLog.token(hi))")
            }
            return n
        }

        let led = trick.ledColor(trump: trump)
        let winner = GameState.trickWinner(trick, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: view.me)
                          && winner != view.me
        n.append("following  led=\(led.map(HandLog.colorInitial) ?? "—")"
                 + "  currentWinner=\(HandLog.short(winner))"
                 + "  partnerWinning=\(partnerWinning)")

        if partnerWinning {
            // The crux flag: when the partner-dump is judged unsafe the agent
            // drops into the "take it myself" branch, which is what makes it
            // overtake its own partner (and can surface a Tiger smash).
            let overturnable = canBeOverturned(
                trick: trick, onTable: trick.plays,
                trump: trump, inference: inference, view: view)
            n.append(overturnable
                ? "partner-dump UNSAFE — trick judged still overturnable, "
                  + "so 'take it myself' candidates are in play"
                : "partner-dump SAFE — partner's win is uncontested")
        }
        if let l = led, let hi = inference.highestOutInColor(l) {
            n.append("highest \(HandLog.colorName(l)) still out (at someone else): \(HandLog.token(hi))")
        }
        let held = inference.knownDeclarerHoldings()
        if !held.isEmpty {
            n.append("declarer must still hold (from widow): "
                     + held.map(HandLog.token).sorted().joined(separator: " "))
        }
        return n
    }

    /// Build the candidate list MCTS evaluates. This is where the human
    /// principles live: we trim from the full legal set down to "moves a
    /// strong player would seriously consider".
    /// Internal (not private) so the specials-rescue invariant below is
    /// directly testable without MCTS in the loop.
    /// `forceNarrow` runs the heuristic narrowing even when the profile's
    /// `searchAllLegalMoves` is on — used to give the IS-MCTS ROOT a small
    /// candidate set (so iterations concentrate) while the tree still searches
    /// all legal replies deeper. The PIMC path and the trace use the normal
    /// (full-width-respecting) call.
    func trickShortlist(view: PlayerView,
                        legal: [Move],
                        inference: TableInference,
                        forceNarrow: Bool = false) -> [Move] {
        // FULL-WIDTH SEARCH (A/B lever): no gate at all — MCTS grades every
        // legal move. Omission failures become structurally impossible.
        if difficulty.searchAllLegalMoves && !forceNarrow { return legal }

        let playCards = legal.compactMap { $0.playedCard }
        guard !playCards.isEmpty,
              let trump = view.trump else { return legal }

        let trick = view.currentTrick
        let onTable = trick?.plays ?? []
        let isLeading = onTable.isEmpty
        var candidates: [Card] = []

        if isLeading {
            candidates = leadShortlist(view: view, plays: playCards,
                                       trump: trump, inference: inference)
        } else {
            candidates = followShortlist(view: view, plays: playCards,
                                         trick: trick!, trump: trump,
                                         inference: inference)
        }
        // De-dup, cap, and ensure non-empty.
        let dedup = uniq(candidates)
        let capped = Array(dedup.prefix(difficulty.trickCandidates))
        var finalCards = capped.isEmpty ? Array(playCards.prefix(difficulty.trickCandidates)) : capped
        // SPECIALS RESCUE: never let a legal Bull/Bear be silently dropped by
        // a singleton shortlist. A singleton skips MCTS entirely, so a one-
        // line shed comparator ends up deciding six-figure special sequencing
        // on its own (it has kept the Bull and spent the Bear — backwards —
        // letting the final trick get doubled against us). Appending the
        // dropped special forces the search to arbitrate.
        if finalCards.count == 1 {
            for c in playCards where (c.isBull || c.isBear) && !finalCards.contains(c) {
                finalCards.append(c)
            }
        }
        return finalCards.map { .play($0) }
    }

    // ---- Lead shortlist

    private func leadShortlist(view: PlayerView,
                               plays: [Card],
                               trump: CardColor,
                               inference: TableInference) -> [Card] {
        let amDeclarer = (view.me == view.highBidder)
        let myTrump = plays.filter { $0.effectiveColor(trump: trump) == trump }
        let trumpOut = inference.trumpStillOutInOpponentsAndPartner
        let tigerOut = inference.isTigerOut
        var picks: [Card] = []

        // 1. Pull-trump: declarer with length + Tiger or other big trump out.
        if amDeclarer && myTrump.count >= 4 && (trumpOut >= 2 || tigerOut) {
            let lowTrump = myTrump
                .filter { !$0.isMoney && !$0.isSpecial }
                .min { rankOf($0) < rankOf($1) }
            if let c = lowTrump { picks.append(c) }

            // Lead-high-to-pull: leading the LOWEST trump donates the round to
            // any higher trump an opponent still holds (and any money they bank
            // on it). When I hold the boss trump I can instead pull from the
            // top — the round still WINS and I keep the lead. Offer the highest
            // NON-special trump that commands the suit (keeping the Tiger in
            // reserve to ruff); fall back to a commanding special (the Tiger)
            // only when nothing else controls. MCTS then weighs high vs low.
            let commanding = myTrump
                .filter { inference.iControlColor($0) }
                .sorted { rankOf($0) > rankOf($1) }
            if let topNonSpecial = commanding.first(where: { !$0.isSpecial }) {
                picks.append(topNonSpecial)
            } else if let boss = commanding.first {
                picks.append(boss)
            }
        }

        // 2. $40k of a virgin (un-led) non-trump color.
        for color in CardColor.allCases where color != trump {
            if inference.hasBeenLed(color) { continue }
            for c in plays where c.effectiveColor(trump: trump) == color {
                if case .colored(_, let r) = c, r == .money40k { picks.append(c) }
            }
        }

        // 3. A controlled (highest-of-color, no void-trump risk) non-trump card.
        if let safe = sureLeadNonTrump(plays: plays, trump: trump, inference: inference) {
            picks.append(safe)
        }

        // 4. Trumps pulled → cash highest trump.
        if trumpOut == 0 && !tigerOut {
            if let high = myTrump.max(by: { rankOf($0) < rankOf($1) }) {
                picks.append(high)
            }
        }

        // 5. Low non-money, non-special — preferring shortest non-trump suit.
        if let lo = lowSafeLead(plays: plays, hand: view.myHand, trump: trump) {
            picks.append(lo)
        }

        // 6. Last resort: cheapest of anything legal.
        if picks.isEmpty {
            if let any = plays.min(by: { PlayoutPolicy.strength($0, led: nil, trump: trump)
                                       < PlayoutPolicy.strength($1, led: nil, trump: trump) }) {
                picks.append(any)
            }
        }
        return picks
    }

    private func sureLeadNonTrump(plays: [Card],
                                  trump: CardColor,
                                  inference: TableInference) -> Card? {
        let candidates = plays.filter {
            !$0.isSpecial && $0.effectiveColor(trump: trump) != trump
        }.sorted { rankOf($0) > rankOf($1) }

        for card in candidates {
            guard let color = card.effectiveColor(trump: trump) else { continue }
            if !inference.iControlColor(card) { continue }
            // Anyone known void in this color? They can trump.
            let voidAny = Seats.all.contains {
                $0 != inference.me && inference.isKnownVoid($0, in: color)
            }
            if voidAny { continue }
            return card
        }
        return nil
    }

    private func lowSafeLead(plays: [Card], hand: [Card], trump: CardColor) -> Card? {
        let cands = plays.filter { !$0.isMoney && !$0.isSpecial
                                && $0.effectiveColor(trump: trump) != trump }
        guard !cands.isEmpty else { return nil }
        var bySuit: [CardColor: Int] = [:]
        for c in hand {
            if case .colored(let col, _) = c, col != trump {
                bySuit[col, default: 0] += 1
            }
        }
        return cands.min { a, b in
            let sa = a.suitColorOrNil.map { bySuit[$0] ?? 99 } ?? 99
            let sb = b.suitColorOrNil.map { bySuit[$0] ?? 99 } ?? 99
            if sa != sb { return sa < sb }
            return rankOf(a) < rankOf(b)
        }
    }

    // ---- Follow shortlist

    private func followShortlist(view: PlayerView,
                                 plays: [Card],
                                 trick: Trick,
                                 trump: CardColor,
                                 inference: TableInference) -> [Card] {
        let onTable = trick.plays
        let provisional = Trick(leader: trick.leader, plays: onTable)
        let winner = GameState.trickWinner(provisional, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: view.me)
                          && winner != view.me
        let moneyOnTable = onTable.reduce(0) { $0 + $1.card.moneyValue }
        // EFFECTIVE worth (Bull/Bear applied): a trick already Beared is worth
        // 0, so we must never bank money into it or fight to take it.
        let effValue = PlayoutPolicy.tableValue(onTable)
        let beared = PlayoutPolicy.tableIsBeared(onTable)
        let led = provisional.ledColor(trump: trump)
        let amLastToPlay = onTable.count == Seats.count - 1

        let mustFollow = led != nil
            && plays.contains { $0.effectiveColor(trump: trump) == led }
        let pool = mustFollow
            ? plays.filter { $0.effectiveColor(trump: trump) == led }
            : plays

        func wouldWin(_ c: Card) -> Bool {
            var t = onTable
            t.append(PlayedCard(player: view.me, card: c))
            return GameState.trickWinner(
                Trick(leader: trick.leader, plays: t), trump: trump) == view.me
        }

        var picks: [Card] = []

        // A. Partner winning + safe → dump money to them, BUT preserve
        //    secondary controllers (principle 8: don't dump $30k onto
        //    partner's $40k — keep it to control the next round of that
        //    color).
        if partnerWinning {
            let safe = amLastToPlay
                || !canBeOverturned(trick: trick, onTable: onTable,
                                     trump: trump, inference: inference,
                                     view: view)
            if safe {
                // A Bull doubles a partner-winning money trick, and flips an
                // already-Beared one back to base×2 for us — a candidate even
                // when the trick is currently Beared. With NO money on the
                // table it's still a candidate: doubling $0 costs nothing and
                // partner's safe trick is a free exit for a Bull that would
                // otherwise be FORCED onto the final trick (doubling it for
                // whoever wins — the recurring endgame disaster).
                if !mustFollow, let bull = plays.first(where: { if case .bull = $0 { return true }; return false }) {
                    picks.append(bull)
                }
                // VALUE-SAFETY: if the trick is already Beared (worth 0), or a
                // loose Bear can still land on it from a yet-to-play opponent,
                // any money we add is wasted/fed to the Bear. In that case
                // offer ONLY the low non-money shed — no money-dump candidate.
                let bearThreat = !amLastToPlay
                    && inference.opponentCanBearTrick(led: led, currentTrick: trick)
                if !beared && !bearThreat {
                    // Cards that are MY highest of their color are future
                    // controllers — try not to dump them.
                    let myTops = topOfEachColorInMyHand(view.myHand, trump: trump)
                    let nonControllers = pool.filter { c in
                        guard let color = c.effectiveColor(trump: trump) else { return true }
                        return myTops[color] != c
                    }
                    let dumpFrom = nonControllers.isEmpty ? pool : nonControllers
                    if let hi = dumpFrom.filter({ $0.isMoney }).max(by: { rankOf($0) < rankOf($1) }) {
                        picks.append(hi)
                    }
                }
                // Hedge: cheapest non-money non-special. Never the Bear
                // (it would cancel partner's money trick — disastrous). This
                // is the only money-safe option under a Bear threat.
                let safeLow = pool.filter { !$0.isSpecial && !$0.isMoney }
                let lowPool = safeLow.isEmpty ? pool.filter { !$0.isSpecial } : safeLow
                if let lo = lowPool.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                            < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                    picks.append(lo)
                }
                return picks
            }
        }

        // B. I can take it. A Beared trick is worth 0 — never fight for it or
        //    bank money into it; use effective value, not the raw money sum.
        let winners = pool.filter(wouldWin)
        let worthTaking = !beared && (effValue >= 5_000 || !partnerWinning)
        if !winners.isEmpty && worthTaking {
            // Cheapest winner — and the most expensive (a Tiger smash on a
            // big money trick is sometimes right; let MCTS decide).
            if let cheap = winners.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                            < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                picks.append(cheap)
            }
            if winners.count > 1,
               let big = winners.max(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                           < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                picks.append(big)
            }
            // BANK MONEY: when last to play the win is certain, so capturing
            // WITH a money card locks it in rather than stranding it for the
            // other team. Offer the highest-money winner as its own candidate
            // (the strength-based "big" above can pick a trump over money).
            if amLastToPlay,
               let bank = winners.filter({ $0.isMoney }).max(by: { $0.moneyValue < $1.moneyValue }) {
                picks.append(bank)
            }
            // BULL ESCAPE: winning a near-worthless pot is not obviously
            // better than ditching the Bull on it (it's only legal here
            // because we can't follow). Held too long, the Bull is FORCED
            // onto the final trick and doubles it for whoever wins — offer
            // the exit and let MCTS weigh it against taking the trick.
            // (Never onto a Beared trick: a Bull after the Bear flips the
            // trick back to ×2 for its winner.)
            if !beared, effValue <= 10_000,
               let bull = pool.first(where: { $0.isBull }) {
                picks.append(bull)
            }
            // Also a cheap shed in case "win" is more expensive than the
            // trick is worth.
            if let sh = cheapShed(pool, led: led, trump: trump) {
                picks.append(sh)
            }
            return picks
        }

        // C. Bear on opponent money trick we can't take. Lower the bar when a
        // loose Bull could still double the pot for their side.
        if !partnerWinning && !mustFollow {
            let bullDoubles = inference.opponentCanBullTrick(led: led, currentTrick: trick)
            // effValue is 0 if the trick is already Beared, so we never line up
            // a second, wasted Bear.
            if effValue >= 10_000 || (bullDoubles && moneyOnTable > 0) {
                if let bear = plays.first(where: { if case .bear = $0 { return true }; return false }) {
                    picks.append(bear)
                }
            }
        }

        // BULL ESCAPE on a trick we're not winning: when the pot is small the
        // Bull costs little here, while holding it risks the forced final-
        // trick double. Offer it; MCTS arbitrates. (Never onto a Beared
        // trick — a Bull after the Bear flips it back to ×2 for its winner.)
        if !partnerWinning, !beared, effValue <= 10_000,
           let bull = pool.first(where: { $0.isBull }) {
            picks.append(bull)
        }

        // D. Default — shed cheapest. When we're feeding an opponent-controlled
        // trick that already holds money, the Bull would double their take, so it
        // must NOT be offered as the cheap shed (the Bear stays cheap — it cancels).
        let bullIsCostly = !partnerWinning && moneyOnTable > 0
        if let lo = cheapShed(pool, led: led, trump: trump, bullIsCostly: bullIsCostly) {
            picks.append(lo)
        }
        if !mustFollow, let v = voidCreatingShed(pool: plays, view: view, trump: trump) {
            picks.append(v)
        }
        return picks
    }

    /// Can a yet-to-play seat overturn the partner-winning play?
    private func canBeOverturned(trick: Trick,
                                 onTable: [PlayedCard],
                                 trump: CardColor,
                                 inference: TableInference,
                                 view: PlayerView) -> Bool {
        let played = Set(onTable.map(\.player))
        let yetToPlay = Seats.all.filter { !played.contains($0) && $0 != view.me }
        if yetToPlay.isEmpty { return false }

        let winner = GameState.trickWinner(trick, trump: trump)
        let winnerCard = onTable.first { $0.player == winner }!.card
        let led = trick.ledColor(trump: trump)
        let winnerStrength = PlayoutPolicy.strength(winnerCard, led: led, trump: trump)

        for s in yetToPlay {
            // If they're an opponent: do THEY potentially still hold a card
            // that beats the current winner? Use inference's "highestOut"
            // logic, conservatively.
            if Seats.team(of: s) == Seats.team(of: view.me) { continue }   // partner — not an over-turner
            // Trump over-ruff possibility: known void in led suit AND
            // trump still out at the table.
            if let l = led, l != trump,
               inference.isKnownVoid(s, in: l),
               (inference.trumpStillOutInOpponentsAndPartner > 0
                || inference.isTigerOut) {
                return true
            }
            // Higher card of led color.
            if let l = led, let top = inference.highestOutInColor(l) {
                if PlayoutPolicy.strength(top, led: led, trump: trump) > winnerStrength {
                    return true
                }
            }
            // Widow knowledge (principle 11): if this opponent is the
            // declarer, anything from the un-discardable widow is in
            // their hand RIGHT NOW. The Tiger is the strongest single
            // case — if the led suit is trump (or partner is winning
            // on trump), declarer's Tiger beats everything.
            for known in inference.knownDeclarerHoldings()
                    where inference.isCardKnownIn(s, card: known) {
                if PlayoutPolicy.strength(known, led: led, trump: trump)
                    > winnerStrength {
                    return true
                }
            }
        }
        return false
    }

    /// A shed that voids me out of a side suit (singleton non-money).
    private func voidCreatingShed(pool: [Card],
                                   view: PlayerView,
                                   trump: CardColor) -> Card? {
        var bySuit: [CardColor: Int] = [:]
        for c in view.myHand {
            if case .colored(let col, _) = c, col != trump {
                bySuit[col, default: 0] += 1
            }
        }
        for c in pool {
            if case .colored(let col, let r) = c,
               col != trump, !r.isMoney,
               (bySuit[col] ?? 0) == 1 {
                return c
            }
        }
        return nil
    }

    private func cheapShed(_ cards: [Card],
                            led: CardColor?,
                            trump: CardColor,
                            bullIsCostly: Bool = false) -> Card? {
        guard !cards.isEmpty else { return nil }
        return cards.min { a, b in
            if bullIsCostly && a.isBull != b.isBull { return b.isBull }
            if a.isMoney != b.isMoney { return !a.isMoney }
            if a.isSpecial != b.isSpecial { return !a.isSpecial }
            if a.moneyValue != b.moneyValue { return a.moneyValue < b.moneyValue }
            return PlayoutPolicy.strength(a, led: led, trump: trump)
                 < PlayoutPolicy.strength(b, led: led, trump: trump)
        }
    }

    // MARK: - Rollout + scoring

    /// Score one (world × candidate) continuation: roll the determinized
    /// state forward with the greedy PlayoutPolicy and return the utility of
    /// the settled hand. With `exactGate > 0`, hand off to EndgameSolver as
    /// soon as the side to act holds ≤ gate cards — the remainder of the
    /// hand is then played PERFECTLY by all four seats (each maximising its
    /// own team's utility) instead of greedily. When the root decision is
    /// inside the exact window the handoff fires on the first iteration, so
    /// no greedy step runs at all. If a solve exceeds its node budget
    /// (pathological width — does not happen at the intended gates), the
    /// gate is dropped for the rest of this continuation and the greedy
    /// policy finishes the hand: never a wrong answer, just a softer one.
    private func evaluateWorld(_ start: GameState,
                               myTeam: Int,
                               baseline: [Int: Int],
                               exactGate: Int) -> Double {
        var s = start
        var steps = 0
        var solverLive = exactGate > 0
        while s.phase != .handComplete && steps < 600 {
            if solverLive, (s.hands[s.toAct]?.count ?? .max) <= exactGate {
                if let v = EndgameSolver.solve(s, myTeam: myTeam, leaf: {
                    utility($0, myTeam: myTeam, baseline: baseline)
                }) {
                    return v
                }
                solverLive = false
            }
            let mv = PlayoutPolicy.move(in: s, seat: s.toAct,
                                        commandingPull: difficulty.rolloutCommandingPull,
                                        specialEscape: difficulty.rolloutSpecialEscape,
                                        topPull: difficulty.rolloutTopPull,
                                        establishDuck: difficulty.rolloutEstablishDuck,
                                        bankWin: difficulty.rolloutBankWin)
            guard let ns = try? s.applying(mv, by: s.toAct) else { break }
            s = ns
            steps += 1
        }
        return utility(s, myTeam: myTeam, baseline: baseline)
    }

    private func teamNet(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Int {
        let mine = (final.matchScore[myTeam] ?? 0) - (baseline[myTeam] ?? 0)
        let opp  = (final.matchScore[1 - myTeam] ?? 0) - (baseline[1 - myTeam] ?? 0)
        return mine - opp
    }

    /// The value MCTS maximises for one rolled-out world. Pure team net
    /// (dollars) by default; with `matchWinWeight > 0` it blends in match-win
    /// probability so play becomes match-aware: utility = net + W·P(win).
    /// teamNet already prices the made/set discontinuity (set-back flows
    /// through scoring); the P term adds the MATCH context it lacks — risking
    /// a set matters more at $900k than at $200k, and a hand that crosses the
    /// $1M line is worth everything. Logistic P keeps a useful gradient when
    /// the match is live and goes flat when it's lopsided, where the dollar
    /// term takes back over (the blend, not pure win-prob, for exactly that
    /// washout reason).
    private func utility(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Double {
        let net = Double(teamNet(final, myTeam: myTeam, baseline: baseline))
        let w = difficulty.matchWinWeight
        guard w > 0 else { return net }

        let mine = Double(final.matchScore[myTeam] ?? 0)
        let theirs = Double(final.matchScore[1 - myTeam] ?? 0)
        let goal = 1_000_000.0
        let p: Double
        if mine >= goal || theirs >= goal {
            if mine >= goal && theirs >= goal {
                // Both crossed on this hand: the standard endgame rule gives
                // the match to the team that won the bid.
                let bidTeam = final.highBidder.map { Seats.team(of: $0) }
                p = (bidTeam == myTeam) ? 1.0 : 0.0
            } else {
                p = mine >= goal ? 1.0 : 0.0
            }
        } else {
            // Logistic in the score lead; $300k of lead ≈ 73% to win. Scale
            // chosen so typical hand swings (±$200-400k) move P meaningfully
            // without saturating mid-match. TUNE alongside matchWinWeight.
            p = 1.0 / (1.0 + exp(-(mine - theirs) / 300_000.0))
        }
        return net + w * p
    }

    // MARK: - Small helpers

    /// Near-tie preference for `decideTrickPlay` (lower tuple = preferred,
    /// compared lexicographically). Layers, in order:
    ///   1. specials are never spent on a tie (Tiger worst, then Bull/Bear);
    ///   2. CERTAIN money — when MY TEAM is safely taking the trick (I win it,
    ///      or a partner does uncontestably), BANK the most (−); otherwise
    ///      commit the LEAST (+) — both when donating to an opponent's trick
    ///      AND when leading (a led money card is exposed to the last, opponent,
    ///      player). `bankToOwnTeam` is false when leading (no winner yet);
    ///   3. conserve trump over off-suit;
    ///   4. lowest rank.
    /// Internal (not private) so the ordering is unit-testable without MCTS
    /// in the loop.
    static func tiePreference(_ c: Card, trump: CardColor,
                              bankToOwnTeam: Bool) -> (Int, Int, Int, Int) {
        let specialClass: Int
        switch c {
        case .tiger:       specialClass = 2
        case .bull, .bear: specialClass = 1
        default:           specialClass = 0
        }
        let moneyTerm = bankToOwnTeam ? -c.moneyValue : c.moneyValue
        let isTrump = (c.effectiveColor(trump: trump) == trump) ? 1 : 0
        return (specialClass, moneyTerm, isTrump, PlayoutPolicy.rankOf(c))
    }

    private func shouldBlunder() -> Bool {
        guard difficulty.blunderRate > 0 else { return false }
        return Double(seedBox.nextInt(upperBound: 10_000)) / 10_000.0
             < difficulty.blunderRate
    }
    private func intRand(_ upper: Int) -> Int {
        upper <= 0 ? 0 : seedBox.nextInt(upperBound: upper)
    }
    private func cardRank(_ c: Card) -> Int {
        if case .colored(_, let r) = c { return r.rawValue }
        return 0
    }
    private func rankOf(_ c: Card) -> Int { PlayoutPolicy.rankOf(c) }

    private func uniq(_ cards: [Card]) -> [Card] {
        var seen: Set<Card> = []
        var out: [Card] = []
        for c in cards where !seen.contains(c) {
            seen.insert(c); out.append(c)
        }
        return out
    }

    /// For each effective color in my hand, the highest-ranking card I
    /// hold. Used to detect "controllers" — cards that win the next
    /// round of that color and should NOT be dumped onto partner.
    /// Tiger is treated as trump's controller candidate (rank 13).
    private func topOfEachColorInMyHand(_ hand: [Card],
                                        trump: CardColor) -> [CardColor: Card] {
        var top: [CardColor: Card] = [:]
        for c in hand {
            guard let color = c.effectiveColor(trump: trump) else { continue }
            if let cur = top[color] {
                if rankOf(c) > rankOf(cur) { top[color] = c }
            } else {
                top[color] = c
            }
        }
        return top
    }
}

// Preserve the RNGBox raw accessor that other files depend on.
extension RNGBox {
    func nextRaw() -> UInt64 { UInt64(nextInt(upperBound: Int.max)) }
}

// MARK: - Card convenience

private extension Card {
    var suitColorOrNil: CardColor? {
        if case .colored(let c, _) = self { return c }
        return nil
    }
}
