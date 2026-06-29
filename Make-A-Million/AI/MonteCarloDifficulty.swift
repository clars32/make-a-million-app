//
//  MonteCarloDifficulty.swift
//  Make-a-Million
//
//  The MonteCarloAgent tuning profile — the shipped strength knobs up top,
//  the A/B-gated research levers walled off in a nested `ResearchLevers` —
//  split out of MonteCarloAgent.swift so the agent file stays focused on
//  decision logic. Declared as an extension so every reference stays
//  `MonteCarloAgent.Difficulty`, unchanged.
//
//  WHY THE SPLIT: `Difficulty` had grown ~30 fields, most of them default-off
//  experiments that no shipped tier (`easy`/`normal`/`hard`/`extreme`) ever
//  sets. Interleaving them with the production knobs made the live decision
//  path hard to read. The default-off levers now live in `research`
//  (`Difficulty.research.useISMCTS`, …); the top-level fields are exactly the
//  ones a shipped tier tunes. `research` defaults to all-off, so the tier
//  initializers are unaffected.
//

import Foundation

extension MonteCarloAgent {

    nonisolated struct Difficulty {
        // ── Play style: which decision stack drives this profile ────────────
        /// `.adaptive` runs the MCTS / search stack — full-width PIMC, the
        /// exact endgame, the rollout/research levers below. It is the research
        /// baseline and the off-ladder expert side-door. `.traditional` runs the
        /// legible principle ladder (`decide*Traditional`): every move has a
        /// nameable reason, strength rises by capability depth, never by error.
        /// Default `.adaptive` so every existing preset/test is behaviour-
        /// unchanged until a profile opts into `.traditional`.
        nonisolated enum Style: String, Codable, Sendable { case traditional, adaptive }
        var style: Style = .adaptive

        // ── Traditional capability ladder (used when style == .traditional) ─
        /// How many principle layers the shortlist applies. Each rung adds a
        /// nameable skill a human would also learn next (see `Capabilities`).
        nonisolated enum PrincipleLevel: Int, Comparable, Codable, Sendable {
            case core, cooperative, positional, complete
            static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        }
        /// How much the table-read (`TableInference`) deduces. Gates void
        /// tracking, card counting, and count-exhaustion deductions.
        nonisolated enum InferenceLevel: Int, Comparable, Codable, Sendable {
            case none, voids, counting, deep
            static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        }
        /// The Traditional ladder's capability set. Coupled by the presets
        /// (e.g. `.positional` principles want `.counting` inference for
        /// `iControlColor`); the individual fields stay settable so tests/A-Bs
        /// can probe combos. Ignored entirely when `style == .adaptive`.
        nonisolated struct Capabilities: Sendable {
            var principles: PrincipleLevel
            var inference: InferenceLevel
            /// Resolve genuine forks by a bounded search confined to the
            /// co-principled candidate set; false → resolve by shortlist
            /// priority (deterministic).
            var plansAhead: Bool
            /// Worlds sampled per fork when `plansAhead`.
            var forkSamples: Int
        }
        var capabilities: Capabilities = Capabilities(principles: .complete,
                                                      inference: .deep,
                                                      plansAhead: true,
                                                      forkSamples: 20)

        // ── Shipped strength knobs (set by the player-facing tiers) ─────────
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

        /// The table-reading depth this profile builds `TableInference` at.
        /// Traditional reads it off the capability ladder; Adaptive maps its
        /// legacy `deepInference` flag (deep when set, otherwise full counting —
        /// the behaviour the boolean encoded before the ladder existed).
        var inferenceLevel: InferenceLevel {
            style == .traditional ? capabilities.inference
                                  : (deepInference ? .deep : .counting)
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

        /// Staying-power discipline for LEAD bids. When our team does NOT hold the
        /// high bid and BOTH our partner and an opponent are still live to act, a
        /// marginal bid we'd abandon at the opponents' very next raise only
        /// misleads the partner into deferring — and a pass is PERMANENT
        /// (`GameEngine.applyBid` / `advanceBidder` skip passed seats forever) —
        /// before we fold and hand the opponents a cheap contract. In that window,
        /// require the bidding ceiling to clear the cheapest legal bid by
        /// `bidEntryMargin` (i.e. survive one opponent raise); otherwise pass and
        /// let the live partner lead instead. OUTSIDE that window — partner already
        /// passed (no one left to mislead), or all opponents out (our bid WINS) —
        /// we bid the full ceiling unchanged: this is NOT global passivity, it is
        /// "don't open the team's bidding on a hand you can't carry while your
        /// partner can still take it." `Bidding.raiseIncrement` = survive exactly
        /// one minimum raise; 0 disables. Targets the human-partner false-signal
        /// pitfall, which is INVISIBLE to symmetric self-play (a bot partner does
        /// not defer to a signal) — so read its flip-rate (`BidGateStats`), not
        /// win-rate, when tuning. A/B `testSelfPlayBidEntryMargin`.
        ///
        /// MEASURED + KEPT ON (June 28 2026, all tiers, margin = raiseIncrement).
        /// Paired 60 / baseSeed 1, Normal: control (gate-off both) challenger 57%
        /// (= seat noise, identical profiles) set 24/29 → treatment (gate-on vs
        /// gate-off) 48%, bid-share 52%→51%, set-rate 24% vs 23%. Flip-rate
        /// 60/530 = 11% of in-window lead bids passed. The win-rate dip is
        /// noise-band (−9pp ≈ 1.4σ at N=60) AND the expected signature: a
        /// partner-deference fix has NO upside in symmetric self-play and a tiny
        /// concession cost, so neutral-to-slightly-negative is the PASS read. The
        /// reads that matter are healthy: flip-rate low (not over-passing),
        /// bid-share −1pp (it DELEGATES thin leads to the partner, doesn't abandon
        /// auctions), set-rate flat (no bidding-quality harm). Real validation is
        /// the handlog / human-partner loop, not the arena.
        var bidEntryMargin: Int = Bidding.raiseIncrement

        /// A/B-gated research levers — default-off experiments that no shipped
        /// tier sets. Walled off here so the production fields above are exactly
        /// the knobs the strength ladder tunes. Access as
        /// `difficulty.research.<lever>`; flip one in a paired self-play probe to
        /// measure it. See `ResearchLevers` for the per-lever findings.
        var research = ResearchLevers()

        /// The parked / under-investigation tuning levers. Every field defaults
        /// OFF and is excluded from the shipped tiers; each carries the paired
        /// self-play result that justified parking it (so a future pass starts
        /// from the evidence, not a re-derivation).
        nonisolated struct ResearchLevers {
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
        }

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

        // ── Traditional ladder (style == .traditional) ─────────────────────
        // The player-facing strength ladder. Each rung adds a NAMEABLE skill a
        // human would learn next; weakness is REDUCED CAPABILITY, not injected
        // error (blunderRate stays 0 at every rung). Scalar bidding everywhere
        // (rolloutBidEval is an Adaptive feature). `samples`/`trickCandidates`
        // shape the bounded fork search; `capabilities` is the real lever.

        /// `Novice` — the basics, cleanly: follow suit, take cheap, shed low,
        /// dump money to a winning partner. No table-reading, no look-ahead.
        static let novice  = Difficulty(style: .traditional,
                                        capabilities: .init(principles: .core,
                                                            inference: .none,
                                                            plansAhead: false,
                                                            forkSamples: 0),
                                        samples: 8, blunderRate: 0.0,
                                        bidAggression: 0.85, partnerRespect: 0.95,
                                        matchAwareness: 0.5, trickCandidates: 3,
                                        bidLeanStrength: 0.0,
                                        calibratedValuation: false)
        /// `Casual` — adds money sense and basic defense: don't waste big money,
        /// Bear an enemy money trick, bank when safely winning. Tracks voids.
        static let casual  = Difficulty(style: .traditional,
                                        capabilities: .init(principles: .cooperative,
                                                            inference: .voids,
                                                            plansAhead: false,
                                                            forkSamples: 0),
                                        samples: 12, blunderRate: 0.0,
                                        bidAggression: 1.00, partnerRespect: 0.85,
                                        matchAwareness: 0.75, trickCandidates: 4,
                                        bidLeanStrength: 0.0,
                                        calibratedValuation: false)
        /// `Skilled` — positional play and counting: preserve controllers, lead
        /// the $40k on a virgin suit, pull trump as declarer, count cards, and
        /// plan one move ahead at clear forks.
        static let skilled = Difficulty(style: .traditional,
                                        capabilities: .init(principles: .positional,
                                                            inference: .counting,
                                                            plansAhead: true,
                                                            forkSamples: 12),
                                        samples: 16, blunderRate: 0.0,
                                        bidAggression: 1.00, partnerRespect: 0.78,
                                        matchAwareness: 1.0, trickCandidates: 5,
                                        bidLeanStrength: 1.0)
        /// `Expert` — the complete strong-human game: bear/Bull threats, void
        /// creation, establishment ducks, full count-exhaustion card-counting,
        /// and bounded look-ahead at every genuine fork.
        static let expert  = Difficulty(style: .traditional,
                                        capabilities: .init(principles: .complete,
                                                            inference: .deep,
                                                            plansAhead: true,
                                                            forkSamples: 20),
                                        samples: 20, blunderRate: 0.0,
                                        bidAggression: 1.05, partnerRespect: 0.68,
                                        matchAwareness: 1.0, trickCandidates: 6,
                                        bidLeanStrength: 1.6)

        /// `Adaptive` — the off-ladder expert side-door. Today's strongest
        /// validated search stack (the ex-`extreme` settings): full-width MCTS
        /// over every legal move, exact two-trick endgames, deep card-counting,
        /// distribution-aware bidding, and the match-aware objective. Free to
        /// explore unconventional, possibly-stronger lines — reached by a
        /// deliberate toggle, never by dragging difficulty up.
        static let adaptive = Difficulty.extreme

        /// Player-facing strength tiers. A small, Codable, ordered enum so the
        /// settings layer and UI deal in names, not tuning constants.
        nonisolated enum Level: String, Codable, CaseIterable, Identifiable, Sendable {
            case novice, casual, skilled, expert   // the Traditional ladder (slider)
            case adaptive                          // off-ladder expert side-door

            var id: String { rawValue }

            /// The four Traditional rungs, in slider order. Adaptive is reached
            /// by a separate toggle (Settings), not by sliding past Expert.
            static let ladder: [Level] = [.novice, .casual, .skilled, .expert]

            /// Is this the experimental, off-ladder search mode?
            var isAdaptive: Bool { self == .adaptive }

            var displayName: String {
                switch self {
                case .novice:   return "Novice"
                case .casual:   return "Casual"
                case .skilled:  return "Skilled"
                case .expert:   return "Expert"
                case .adaptive: return "Adaptive"
                }
            }

            /// One-line description for the settings footer — describes the
            /// CAPABILITY each rung adds, since that is what the player chooses.
            var blurb: String {
                switch self {
                case .novice:
                    return "The basics, cleanly: follows suit, takes cheap, and dumps money to a winning partner. Doesn't count cards."
                case .casual:
                    return "Adds money sense and basic defense — won't waste big money, bears an enemy's money trick, and banks when safely winning."
                case .skilled:
                    return "Counts cards and plays positionally: preserves controllers, leads the $40k on a fresh suit, pulls trump, and plans a move ahead."
                case .expert:
                    return "The complete strong-human game — bear/Bull threats, void creation, establishment ducks, full counting, and look-ahead at every fork."
                case .adaptive:
                    return "Experimental. Explores unconventional, sometimes stronger lines instead of fixed principles — for players who already beat Expert."
                }
            }

            /// The tuning profile this level plays with.
            var profile: Difficulty {
                switch self {
                case .novice:   return .novice
                case .casual:   return .casual
                case .skilled:  return .skilled
                case .expert:   return .expert
                case .adaptive: return .adaptive
                }
            }
        }
    }
}
