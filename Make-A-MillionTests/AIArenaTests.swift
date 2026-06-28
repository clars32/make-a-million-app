//
//  AIArenaTests.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/18/26.
//


//
//  AIArenaTests.swift
//  Make-a-MillionTests
//
//  Not really a pass/fail test — it's the instrument. `print` output shows
//  in the Xcode console while the test runs (View → Debug Area, or the
//  Report navigator → the test run → console).
//
//  RUN ORDER (matches how the engine was brought up — smallest slice first):
//    1. testTraceOneHand      — proves the whole AI path executes once
//                               without trapping a precondition or hanging.
//    2. testArenaSmall        — 8 matches, quick statistical smell test.
//    3. testArenaVerdict      — 30 matches, the real number to report back.
//
//  Run them individually (click the diamond next to each) rather than the
//  whole class, so a slow arena run doesn't gate the fast smoke test.
//

import XCTest
@testable import Make_A_Million_Mobile   // module name derives from the app's
                                         //   PRODUCT_NAME ("Make-A-Million Mobile")

final class AIArenaTests: XCTestCase {

    /// Step 1. Fast. If this hangs or red-bars on a precondition, STOP —
    /// that's a wiring/logic bug to fix before any statistics mean anything.
    func testTraceOneHand() async {
        await AIArena.traceOneHand(difficulty: .normal, dealSeed: 1)
    }

    /// Step 2. Small and quick — confirms the arena loop itself works and
    /// gives an early read before committing to the long run.
    func testArenaSmall() async {
        let r = await AIArena.run(matches: 8, difficulty: .normal, baseSeed: 1)
        print(r.summary)
    }

    /// Step 3. The real verdict. This is the number to send back. It may take
    /// a little while — many hands × samples × rollouts — so run it on its
    /// own and let it finish.
    func testArenaVerdict() async {
        let r = await AIArena.run(matches: 30, difficulty: .normal, baseSeed: 1)
        print(r.summary)
        XCTAssertGreaterThan(
            r.mcWinRate, 0.65,
            "Monte Carlo should clearly beat random; got \(r.mcWinRate). "
            + "Below ~0.65 means a bug, not just untuned — see the verdict line.")
    }

    // MARK: - Self-play A/B (bidding calibration instrument)

    /// Baseline: identical profiles should land near 50% and give a reference
    /// for the bid-share / contract / set-rate telemetry.
    func testSelfPlayBaseline() async {
        let r = await AIArena.runSelfPlay(matches: 20, challenger: .normal,
                                          champion: .normal, baseSeed: 1)
        print(r.summary)
    }

    /// Regression guard for the bid calibration: the new default `.normal`
    /// against the previous, more conservative profile. Should be win-rate
    /// neutral, take a few more bids, and not raise the set-rate.
    func testSelfPlayBidCalibration() async {
        // New default `.normal` (challenger) vs the previous, more conservative
        // bid profile (champion). Confirms the calibration is win-rate neutral
        // and keeps the set-rate bounded.
        var oldProfile = MonteCarloAgent.Difficulty.normal
        oldProfile.bidAggression = 0.92
        oldProfile.partnerRespect = 0.85
        let r = await AIArena.runSelfPlay(matches: 20, challenger: .normal,
                                          champion: oldProfile, baseSeed: 1)
        print(r.summary)
    }

    /// A/B for bid-inference in the world sampler: challenger reads the
    /// auction (bidLeanStrength 1.0), champion samples uniformly (0.0).
    /// Expect neutral-or-better win-rate; the feature also makes play more
    /// human-like (it stops crediting passers with monster hands).
    func testSelfPlayBidInference() async {
        var noInference = MonteCarloAgent.Difficulty.normal
        noInference.bidLeanStrength = 0.0
        let r = await AIArena.runSelfPlay(matches: 30, challenger: .normal,
                                          champion: noInference, baseSeed: 1)
        print(r.summary)
    }

    /// A/B for the Extreme widow deduction in isolation: both sides play the
    /// `.normal` profile, the only difference being that the challenger pins the
    /// declarer's un-discardable widow cards into the right seat when sampling
    /// worlds. Expect neutral-or-better win-rate (it removes a class of
    /// impossible worlds the MCTS was averaging over). Isolated from Extreme's
    /// other levers (samples/shortlist) so the delta is the deduction alone.
    /// Widow deduction (`deduceWidowHoldings`) is now ON by default for every
    /// tier; this A/B keeps the lever honest by turning it OFF on the champion.
    ///
    /// READING THIS: the printed VERDICT compares to 50% and so IGNORES the
    /// seat/seed confound — don't trust it. Compare against the same-seed
    /// off-vs-off control instead. Measured paired, baseSeed 1:
    ///   • 60 matches: control 45% → treatment 52% (set-rate 21%→17%)
    ///   • 80 matches: control 46% → treatment 54% (set-rate 20%→17%)
    /// A real +~7–8pp, consistent with the deduction being provably correct
    /// (it removes impossible worlds where the declarer's pinned widow cards
    /// sat elsewhere) — which is why it was promoted from Extreme-only to all
    /// tiers.
    func testSelfPlayWidowDeduction() async {
        var off = MonteCarloAgent.Difficulty.normal
        off.deduceWidowHoldings = false   // the "before" profile (default is now on)
        let r = await AIArena.runSelfPlay(matches: 30, challenger: .normal,
                                          champion: off, baseSeed: 1)
        print(r.summary)
    }

    /// A/B for the Extreme `deepInference` (count-exhaustion voids): both sides
    /// play `.normal`; the challenger additionally infers voids from suit
    /// exhaustion. Isolates the deduction from Extreme's other levers. Expect
    /// neutral-or-better (it's provably correct — it only adds true voids).
    /// As always, read it against the same-seed off-vs-off control, NOT 50%.
    /// Read against the same-seed off-vs-off control, NOT 50%. Measured paired
    /// at 60 matches / baseSeed 1: control 55% → treatment 57% (set 18%→17%) —
    /// essentially NEUTRAL (+~2pp / +1 match). Expected: count-exhaustion voids
    /// fire rarely, so the effect is small; it's provably correct (only adds
    /// true voids) and non-regressive, hence kept as an Extreme differentiator
    /// rather than promoted to all tiers.
    func testSelfPlayDeepInference() async {
        var withDeep = MonteCarloAgent.Difficulty.normal
        withDeep.deepInference = true
        let r = await AIArena.runSelfPlay(matches: 30, challenger: withDeep,
                                          champion: .normal, baseSeed: 1)
        print(r.summary)
    }

    /// Tuning probe for the (currently PARKED) `declarerTrumpBias` shape prior:
    /// challenger biases trump toward the declarer when sampling; champion
    /// samples flat. Read against the same-seed control, not 50%. Measured
    /// paired at 60 matches / baseSeed 1: control 55% → treatment 53% at BOTH
    /// 0.4 and 0.8, i.e. −~2pp — so the lever is parked at 0 (see
    /// `Difficulty.research.declarerTrumpBias`). Re-run this after a refinement (bias
    /// only low trump, or reduce `bidLeanStrength` alongside).
    func testSelfPlayTrumpShape() async {
        var withShape = MonteCarloAgent.Difficulty.normal
        withShape.research.declarerTrumpBias = 0.4
        let r = await AIArena.runSelfPlay(matches: 30, challenger: withShape,
                                          champion: .normal, baseSeed: 1)
        print(r.summary)
    }

    /// Does Extreme actually beat Hard? Read TREATMENT against the same-seed
    /// hard-vs-hard CONTROL, not 50%. Extreme adds: more samples (60 vs 36),
    /// a wider shortlist (6 vs 5), a stronger auction read (2.0 vs 1.6), the
    /// exhaustion-void deduction, and slightly less partner-respect.
    func testSelfPlayExtremeVsHard() async {
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .hard,
                                                champion: .hard, baseSeed: 1)
        print("CONTROL (hard vs hard):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: .extreme,
                                          champion: .hard, baseSeed: 1)
        print("TREATMENT (extreme vs hard):\n" + r.summary)
    }

    /// Probe for the (PARKED) `rolloutCommandingPull` rollout change (declarer
    /// draws trump with a commanding high card, not the lowest). Read against
    /// the same-seed control, not 50%. Measured paired, baseSeed 1: 60 matches
    /// 55%→60% looked promising, but 100 matches 55%→56% — i.e. NEUTRAL, the
    /// 60-match bump was noise. Parked off (the lever stays for future work).
    /// Lesson: confirm promising small-N results at higher N before promoting.
    func testSelfPlayCommandingPull() async {
        var withPull = MonteCarloAgent.Difficulty.normal
        withPull.research.rolloutCommandingPull = true
        let r = await AIArena.runSelfPlay(matches: 30, challenger: withPull,
                                          champion: .normal, baseSeed: 1)
        print(r.summary)
    }

    /// Probe for the (PARKED) `rolloutSpecialEscape` rollout change (Bull
    /// endgame management in rollouts: shed the Bull on worthless tricks late;
    /// when trapped with BER+BUL, spend the Bull small and keep the Bear).
    /// NOTE: the agent-side shortlist changes (Bull-escape candidates +
    /// specials rescue) shipped ungated and affect BOTH sides here — this A/B
    /// isolates the ROLLOUT half only. Read TREATMENT against the same-seed
    /// control, not 50%. Measured paired at 60 matches / baseSeed 1:
    /// control 63% → treatment 50% (challenger set-rate 15%→19%) — i.e.
    /// negative-to-noise, so the flag is parked off. The root-candidate fixes
    /// alone cure the observed Bull endplays, and they rely on rollouts
    /// staying pessimistic (the held-Bull catastrophe is the differential
    /// signal MCTS uses to prefer the escape candidate).
    func testSelfPlaySpecialEscape() async {
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        var withEscape = MonteCarloAgent.Difficulty.normal
        withEscape.research.rolloutSpecialEscape = true
        let r = await AIArena.runSelfPlay(matches: 60, challenger: withEscape,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (specialEscape vs normal):\n" + r.summary)
    }

    /// Probe for `searchAllLegalMoves` (no shortlist gate — MCTS grades every
    /// legal move). Eliminates the omission failure class outright at ~2-3×
    /// rollout cost; the risk to measure is selection noise (more candidates,
    /// more chances of a lucky 20-sample mean). Read TREATMENT against the
    /// same-seed control, not 50%. Measured paired at 60 / baseSeed 1:
    /// control 63% → treatment 63% (set 15/23% → 16/24%) — exactly NEUTRAL,
    /// i.e. the noise risk did not materialise. PROMOTED to Hard + Extreme on
    /// robustness grounds (immunity to the omission class at no strength
    /// cost; their higher sample counts only shrink the noise risk further).
    /// Easy/Normal stay curated for the ladder, latency, and arena speed.
    func testSelfPlayAllLegalMoves() async {
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        var fullWidth = MonteCarloAgent.Difficulty.normal
        fullWidth.searchAllLegalMoves = true
        let r = await AIArena.runSelfPlay(matches: 60, challenger: fullWidth,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (all-legal vs normal):\n" + r.summary)
    }

    /// All-phases probe for `matchWinWeight` (match-aware trick-play objective:
    /// utility = teamNet + W·P(win match)). This run reads NEUTRAL (≈control)
    /// because match context is live in only a few hands of a from-scratch
    /// match — too little power. That is NOT a dead lever: the CONDITIONAL
    /// instrument below (`testSelfPlayMatchObjectiveEndgame` / `*LeadProtect`,
    /// which seed every match near the finish) exposed a clear effect, and
    /// matchWinWeight=400k was PROMOTED to Normal/Hard/Extreme. Kept here as the
    /// from-scratch safety check (must stay ≥ neutral — confirms the lever
    /// self-gates and doesn't over-conservatize full matches; current code
    /// 53%→53%).
    func testSelfPlayMatchObjective() async {
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        var matchAware = MonteCarloAgent.Difficulty.normal
        matchAware.matchWinWeight = 400_000
        let r = await AIArena.runSelfPlay(matches: 60, challenger: matchAware,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (matchWinWeight 400k vs normal):\n" + r.summary)
    }

    /// CONDITIONAL INSTRUMENT for `matchWinWeight` (the fix the parked all-phases
    /// probe above asked for). Seeds every match at a TIED near-finish ($750k
    /// each) so the race is decided in 1–3 hands, each played under live
    /// finish-line pressure — exactly where the P-term is steepest. Control
    /// (weight 0) then a weight sweep, all from the same tied start; read each
    /// TREATMENT against the control. If even this concentrated instrument reads
    /// neutral, matchWinWeight is genuinely inert and parks for good.
    func testSelfPlayMatchObjectiveEndgame() async {
        let s = 750_000
        let control = await AIArena.runSelfPlay(matches: 120, challenger: .normal,
                                                champion: .normal, baseSeed: 1,
                                                chalStart: s, champStart: s)
        print("CONTROL (normal vs normal, both $750k):\n" + control.summary)
        for w in [200_000, 400_000, 700_000] {
            var mw = MonteCarloAgent.Difficulty.normal
            mw.matchWinWeight = Double(w)
            let r = await AIArena.runSelfPlay(matches: 120, challenger: mw,
                                              champion: .normal, baseSeed: 1,
                                              chalStart: s, champStart: s)
            print("TREATMENT (matchWinWeight=\(w / 1000)k, both $750k):\n" + r.summary)
        }
    }

    /// Does a match-aware LEADER protect (play safe) and a TRAILER push? Seeds
    /// the challenger ahead (875/625) then behind (625/875), each vs a same-start
    /// control so the delta isolates `matchWinWeight` from the starting edge.
    func testSelfPlayMatchObjectiveLeadProtect() async {
        var mw = MonteCarloAgent.Difficulty.normal
        mw.matchWinWeight = 400_000
        let aheadCtl = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                                 champion: .normal, baseSeed: 1,
                                                 chalStart: 875_000, champStart: 625_000)
        print("CONTROL ahead (normal, 875/625):\n" + aheadCtl.summary)
        let ahead = await AIArena.runSelfPlay(matches: 100, challenger: mw,
                                              champion: .normal, baseSeed: 1,
                                              chalStart: 875_000, champStart: 625_000)
        print("TREATMENT ahead (mw=400k, 875/625):\n" + ahead.summary)
        let behindCtl = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                                  champion: .normal, baseSeed: 1,
                                                  chalStart: 625_000, champStart: 875_000)
        print("CONTROL behind (normal, 625/875):\n" + behindCtl.summary)
        let behind = await AIArena.runSelfPlay(matches: 100, challenger: mw,
                                               champion: .normal, baseSeed: 1,
                                               chalStart: 625_000, champStart: 875_000)
        print("TREATMENT behind (mw=400k, 625/875):\n" + behind.summary)
    }

    /// Lock for the start-score instrument: from $950k each, every match is one
    /// or two hands from the line, so it must conclude almost immediately (not
    /// run a full ~10-hand match — which is what we'd see if the seed were
    /// ignored).
    func testSelfPlayStartScoreSeedsTheCarry() async {
        let r = await AIArena.runSelfPlay(matches: 8, challenger: .normal,
                                          champion: .normal, baseSeed: 1,
                                          chalStart: 950_000, champStart: 950_000)
        XCTAssertEqual(r.failures, 0, "seeded near-finish matches should conclude")
        XCTAssertLessThanOrEqual(r.hands, r.matches * 4,
            "from $950k each, matches should finish in a few hands")
        XCTAssertEqual(r.challengerWins + r.championWins, r.matches - r.failures)
    }

    /// Isolates Extreme's STRENGTH levers from its (suspect, unvalidated) bid
    /// knobs: challenger = Hard + Extreme's search/deduction (samples 60,
    /// shortlist 6, deepInference) but Hard's bidding (bidLean 1.6, respect
    /// 0.68). If this beats the hard-vs-hard control, the search/deduction
    /// levers help and the bid knobs are the drag in full Extreme.
    func testSelfPlayExtremeStrengthLevers() async {
        var strongHard = MonteCarloAgent.Difficulty.hard
        strongHard.samples = 60
        strongHard.trickCandidates = 6
        strongHard.deepInference = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .hard,
                                                champion: .hard, baseSeed: 1)
        print("CONTROL (hard vs hard):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: strongHard,
                                          champion: .hard, baseSeed: 1)
        print("TREATMENT (hard+search+deduction vs hard):\n" + r.summary)
    }

    /// Opponent-free calibration: is the evaluator under-valuing hands (i.e.
    /// passing makeable ones)? Forces each seat to declare at the floor and
    /// compares estimate vs realized gross. Prints the calibration curve.
    func testBidCalibration() async {
        let r = await AIArena.runBidCalibration(deals: 25, difficulty: .normal,
                                                baseSeed: 1)
        print(r.summary)
    }

    /// Bid-frame check for the calibrated evaluator: the per-card refit was
    /// fitted on PLAYING hands; this confirms the pre-widow estimate (which
    /// adds widowEV) is unbiased against realized gross. `widowEV` in the
    /// `.calibrated` branch is the re-zero knob if this reads hot or cold.
    func testBidCalibrationCalibrated() async {
        var profile = MonteCarloAgent.Difficulty.normal
        profile.calibratedValuation = true
        let r = await AIArena.runBidCalibration(deals: 60, difficulty: profile,
                                                baseSeed: 11)
        print(r.summary)
    }

    /// Distillation instrument: mines positions where PlayoutPolicy's move
    /// disagrees with its 1-ply ensemble rollout teacher (full-info argmax
    /// over legal moves, ε-perturbed playouts of the true world, paired sign
    /// test). Prints the recurring disagreement patterns ranked by total
    /// regret, with exemplars — the shopping list for PlayoutPolicy patches.
    /// Not pass/fail; deterministic given (hands, baseSeed, teacher).
    ///
    /// METHOD NOTE: the ε that controls rollout chaos also biases the
    /// teacher toward cashing money early (sloppy futures squander held
    /// money), so only believe patterns that appear under BOTH teacher
    /// configs — this entry runs standard then gentle so the intersection
    /// is always available from one run. The student mines the difficulty's
    /// SHIPPED rollout flags, so a re-run after a lever promotion yields a
    /// fresh table (it won't re-flag fixed patterns).
    func testPolicyDisagreementMining() async {
        let std = await PolicyMiner.mine(hands: 200, difficulty: .normal,
                                         baseSeed: 1, teacher: .standard)
        print("STANDARD TEACHER:\n" + std.summary)
        let gentle = await PolicyMiner.mine(hands: 200, difficulty: .normal,
                                            baseSeed: 1, teacher: .gentle)
        print("GENTLE TEACHER:\n" + gentle.summary)
    }

    /// A/B for the PolicyMiner-derived rollout fix `rolloutTopPull` (the #1
    /// mined pattern: the rollout declarer's low-trump pull loop).
    ///
    /// MEASURED (June 12 2026, the runs that PROMOTED the lever): 60 matches
    /// control 52% → treatment 58%; confirmed at 100 matches control 49% →
    /// treatment 59% (+10pp, set-rate 28%/28%). Since the default is now ON,
    /// this test reproduces the measurement with the roles flipped: the
    /// explicit `oldPull` challenger is yesterday's low-pull rollout and the
    /// default champion carries the promoted fix (expect the challenger to
    /// LOSE by ~10pp against the same-seed control).
    func testSelfPlayRolloutTopPull() async {
        var oldPull = MonteCarloAgent.Difficulty.normal
        oldPull.rolloutTopPull = false
        let control = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 100, challenger: oldPull,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (old low-pull vs topPull default):\n" + r.summary)
    }

    /// A/B for the PolicyMiner-derived rollout fix `rolloutEstablishDuck`
    /// (the #2 mined pattern: cashing a length-protected side-suit boss into
    /// the thin first round). Challenger ducks to establish; champion is the
    /// current default (topPull on both sides).
    ///
    /// MEASURED (June 12 2026, paired 60 / baseSeed 1, control 62%): blanket
    /// duck 52% (NEGATIVE — repeated ducks donate tempo); virgin-only duck
    /// 60% (neutral). PARKED at false — see the lever comment.
    func testSelfPlayEstablishDuck() async {
        var duck = MonteCarloAgent.Difficulty.normal
        duck.research.rolloutEstablishDuck = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: duck,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (rolloutEstablishDuck vs normal):\n" + r.summary)
    }

    /// A/B for the PolicyMiner-derived rollout fix `rolloutBankWin` (top
    /// follow-side family of the post-topPull re-mine, both teacher configs:
    /// "win plain → win money" + "win trump → shed money" ≈ $13-18M total
    /// regret). Challenger banks unassailable money winners mid-trick;
    /// champion is the current default.
    ///
    /// MEASURED (June 12 2026, paired 60 / baseSeed 1): control 62% →
    /// treatment 57% — below the paired control. PARKED at false; the mined
    /// signal aligned with the ε-teacher's greedy bias (see lever comment).
    func testSelfPlayBankWin() async {
        var bank = MonteCarloAgent.Difficulty.normal
        bank.research.rolloutBankWin = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: bank,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (rolloutBankWin vs normal):\n" + r.summary)
    }

    /// A/B for the calibrated evaluator tables: challenger bids / discards /
    /// names trump from the data-fitted `.calibrated` constants, champion
    /// from the original hand-set ones. Trick play is identical on both
    /// sides, so any delta is pure valuation quality. Watch the set-rate as
    /// closely as the win-rate — the refit raises most estimates, so the
    /// failure mode to catch is over-bidding into sets.
    ///
    /// MEASURED (June 2026, the run that PROMOTED `calibratedValuation`):
    /// control 60% → treatment 60% (exactly neutral), bid share 52% → 60%,
    /// avg contract $210k vs $219k, set-rate 26%/26%. Since the default is
    /// now ON, this test reproduces the measurement with the roles flipped:
    /// `calibrated` here is the default profile and the explicit `original`
    /// below is the challenger's old behavior.
    func testSelfPlayCalibratedValuation() async {
        var original = MonteCarloAgent.Difficulty.normal
        original.calibratedValuation = false
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: original,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (original valuation vs calibrated default):\n" + r.summary)
    }

    /// A/B for the EXACT-ENDGAME root lever (`exactEndgameTricks`): when a
    /// real decision arrives with ≤N tricks remaining, every sampled
    /// world × candidate is graded by EndgameSolver (full-information
    /// alpha-beta over engine moves) instead of a greedy rollout. Read
    /// TREATMENT against the same-seed control, not 50%.
    ///
    /// MEASURED (June 12 2026, 60 / baseSeed 1): control 62% (set 24%/34%);
    /// gate 4 → 57% (set 26%/35%). Below the paired control — the
    /// double-dummy trap (see the lever comment): per-world minimax
    /// amplifies residual world-sampling error, and at 4 tricks out the
    /// remaining errors are the decisive ones. See the gate probe below
    /// for the 3/2 sweep that located the crossover; gate 2 was PROMOTED
    /// to Hard + Extreme.
    func testSelfPlayExactEndgameRoot() async {
        var exact = MonteCarloAgent.Difficulty.normal
        exact.exactEndgameTricks = 4
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: exact,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (exactEndgameTricks=4 vs normal):\n" + r.summary)
    }

    /// Gate-size probe for the exact-endgame root lever, TREATMENT-ONLY
    /// (the paired control is deterministic at baseSeed 1 — 62% — so it is
    /// not re-run). Theory under test: at larger gates the per-world
    /// minimax is too "double-dummy" — it amplifies residual world-sampling
    /// error, which the greedy rollout's shared blind spots smooth over.
    ///
    /// MEASURED (June 12 2026, 60 / baseSeed 1, control 62% set 24%):
    /// gate 3 → 55% (set 26%), gate 2 → 62% (set 24% — control exactly).
    /// The sweep confirms the amplification story: 3–4 negative, 2 free.
    /// Gate 2 PROMOTED to Hard + Extreme on the full-width precedent
    /// (neutral strength + structural immunity to the final-two-trick
    /// forced-endplay class); gates ≥3 parked until world sampling gets
    /// sharper (play-consistency filtering is the named candidate).
    func testSelfPlayExactEndgameRootGateProbe() async {
        var gate3 = MonteCarloAgent.Difficulty.normal
        gate3.exactEndgameTricks = 3
        let r3 = await AIArena.runSelfPlay(matches: 60, challenger: gate3,
                                           champion: .normal, baseSeed: 1)
        print("TREATMENT (exactEndgameTricks=3 vs normal):\n" + r3.summary)
        var gate2 = MonteCarloAgent.Difficulty.normal
        gate2.exactEndgameTricks = 2
        let r2 = await AIArena.runSelfPlay(matches: 60, challenger: gate2,
                                           champion: .normal, baseSeed: 1)
        print("TREATMENT (exactEndgameTricks=2 vs normal):\n" + r2.summary)
    }

    /// A/B for the EXACT-ENDGAME rollout-tail lever (`rolloutExactTricks =
    /// 2`): mid-hand rollouts hand off to the solver once the side to act
    /// holds ≤2 cards, so root candidates at tricks 7–11 are graded by
    /// futures whose final two tricks are played perfectly. TREATMENT-ONLY
    /// (the paired control is deterministic at baseSeed 1 — 62%, set 24%).
    ///
    /// MEASURED (June 12 2026, 60 / baseSeed 1): treatment 55% (set 28%) —
    /// below the paired control → PARKED at 0. The upside hypothesis
    /// (exact tails keep TRUE forced-trap differentials, remove false
    /// ones) lost to double-dummy amplification, and no gate escapes it
    /// for tails: the world error a tail solve amplifies is the one
    /// sampled at the MID-HAND root (maximal hidden information),
    /// regardless of how late the solve fires — unlike the root lever,
    /// whose gate-2 worlds are sampled late and pinned. See the lever
    /// comment for the full postmortem.
    func testSelfPlayExactEndgameRolloutTail() async {
        var exact = MonteCarloAgent.Difficulty.normal
        exact.research.rolloutExactTricks = 2
        let r = await AIArena.runSelfPlay(matches: 60, challenger: exact,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (rolloutExactTricks=2 vs normal):\n" + r.summary)
    }

    /// A/B for PLAY-CONSISTENCY world filtering: the challenger rejects sampled
    /// worlds that would force a hidden seat into a provably-dominated past play
    /// (money/Bull donated into a certain loss with a throwaway in hand; the
    /// Bear declined on a fat certain loss). Conceived as the named successor to
    /// the parked exact-endgame gates >=3 — sharper WORLDS, the prerequisite the
    /// double-dummy finding identified. Read TREATMENT against the same-seed
    /// control, not 50%.
    ///
    /// MEASURED (June 12 2026, both checks on, 60 / baseSeed 1): control 62%
    /// (set 24%) → treatment 50% (set 30%) — NEGATIVE, the agent got SET more.
    /// The per-check probe below localises ALL the damage to check (A): the
    /// agents shed by lowest CAPTURE RANK (the $5k/$10k are routinely a seat's
    /// lowest legal card), so (A) reads normal small-money shedding as a
    /// "dominated donation" and deletes the TRUE world. The inference-side
    /// double-dummy trap. PARKED; see the lever comment for the full postmortem.
    func testSelfPlayPlayConsistency() async {
        var filtered = MonteCarloAgent.Difficulty.normal
        filtered.research.filterDominatedDonation = true
        filtered.research.filterBearDecline = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: filtered,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (both consistency checks vs normal):\n" + r.summary)
    }

    /// Per-check probe for play-consistency filtering, TREATMENT-ONLY (the
    /// paired control is deterministic at baseSeed 1 — 62%, set 24%). Locates
    /// which check drives the −12pp combined regression.
    ///
    /// MEASURED (June 12 2026, 60 / baseSeed 1): (A) donation-only → 52%
    /// (set 30%); (B) Bear-only → 62% (set 23%). ALL the damage is (A), which
    /// I'd wrongly expected to be the safe one — the agents shed by lowest
    /// capture RANK, so small money ($5k/$10k) is routinely their lowest legal
    /// card and (A) mis-reads that normal shed as a dominated donation,
    /// deleting the true world. (B) is neutral (the event is rare and honored).
    func testSelfPlayPlayConsistencyPerCheck() async {
        var aOnly = MonteCarloAgent.Difficulty.normal
        aOnly.research.filterDominatedDonation = true
        let rA = await AIArena.runSelfPlay(matches: 60, challenger: aOnly,
                                           champion: .normal, baseSeed: 1)
        print("TREATMENT (donation check only vs normal):\n" + rA.summary)
        var bOnly = MonteCarloAgent.Difficulty.normal
        bOnly.research.filterBearDecline = true
        let rB = await AIArena.runSelfPlay(matches: 60, challenger: bOnly,
                                           champion: .normal, baseSeed: 1)
        print("TREATMENT (Bear-decline check only vs normal):\n" + rB.summary)
    }

    /// A/B for SOFT play-history world weighting: unlike
    /// `playConsistencyFilter`, this does not reject worlds that require a
    /// surprising hidden-seat play. It importance-weights them down/up using
    /// high-confidence card-reading cues, capped so no one rationality
    /// assumption can dominate a decision. This is the safer successor to the
    /// hard play-consistency filter: better hidden-card beliefs without
    /// deleting the true world when the population makes a
    /// normal-but-surprising small-money shed. Read TREATMENT against the
    /// same-seed control, not 50%.
    ///
    /// Run the smoke test below first. This 60-match probe is the strength
    /// read; it is intentionally too slow to be the wiring check.
    func testSelfPlayPlayHistoryWeighting() async {
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        var weighted = MonteCarloAgent.Difficulty.normal
        weighted.research.playHistoryWeighting = 0.45
        let r = await AIArena.runSelfPlay(matches: 60, challenger: weighted,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (soft play-history weighting vs normal):\n" + r.summary)
    }

    /// Cheap wiring/runtime smoke for the soft play-history hook. Uses a tiny
    /// near-finish self-play run and disables rollout bidding so this isolates
    /// trick-play weighted sampling, not bid-rollout cost. This is not a
    /// strength read; it only proves the path starts, finishes, and settles
    /// every seeded match before launching the 60-match probe above.
    func testSelfPlayPlayHistoryWeightingSmoke() async {
        var base = MonteCarloAgent.Difficulty.normal
        base.rolloutBidEval = false
        base.samples = 6
        base.trickCandidates = 3
        base.searchAllLegalMoves = false
        base.exactEndgameTricks = 0

        var weighted = base
        weighted.research.playHistoryWeighting = 0.45

        let matches = 4
        let control = await AIArena.runSelfPlay(matches: matches, challenger: base,
                                                champion: base, baseSeed: 19,
                                                chalStart: 950_000, champStart: 950_000)
        print("SMOKE CONTROL (tiny normal vs normal):\n" + control.summary)
        assertSelfPlaySmoke(control, matches: matches)

        let treatment = await AIArena.runSelfPlay(matches: matches, challenger: weighted,
                                                  champion: base, baseSeed: 19,
                                                  chalStart: 950_000, champStart: 950_000)
        print("SMOKE TREATMENT (tiny soft play-history weighting vs normal):\n"
              + treatment.summary)
        assertSelfPlaySmoke(treatment, matches: matches)
    }

    private func assertSelfPlaySmoke(_ result: AIArena.SelfPlayResult,
                                     matches: Int,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(result.failures, 0, "smoke run should settle every match",
                       file: file, line: line)
        XCTAssertGreaterThan(result.hands, 0, "smoke run should play hands",
                             file: file, line: line)
        XCTAssertLessThanOrEqual(result.hands, matches * 8,
            "near-finish smoke should not drift into a long from-scratch match",
            file: file, line: line)
        XCTAssertEqual(result.challengerWins + result.championWins, matches,
                       "wins plus losses should equal completed matches",
                       file: file, line: line)
    }

    /// A/B for SINGLE-OBSERVER IS-MCTS (`Difficulty.research.useISMCTS`): the challenger
    /// replaces depth-1 PIMC trick search with a determinization-per-iteration
    /// information-set tree (opponents/partner searched, not assumed greedy-
    /// omniscient), compute-matched to the PIMC rollout budget so the read
    /// isolates the ESTIMATOR, not the rollout count. This is the structural
    /// step the double-dummy / inference-trap findings pointed to: PIMC's
    /// strategy fusion is untunable, IS-MCTS removes it without assuming an
    /// opponent-rationality model (the thing that sank play-consistency
    /// filtering). Read TREATMENT against the same-seed control, not 50%.
    func testSelfPlayISMCTS() async {
        var ismcts = MonteCarloAgent.Difficulty.normal
        ismcts.research.useISMCTS = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: ismcts,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (IS-MCTS vs normal):\n" + r.summary)
    }

    /// IS-MCTS iteration-scaling probe, TREATMENT-ONLY (the PIMC control is
    /// unaffected by the multiplier and deterministic at baseSeed 1 — 57% set
    /// 30%, measured in `testSelfPlayISMCTS` on this build). At ×1 IS-MCTS read
    /// 48% (≈80 iterations — a sparse 2-ply tree). The decisive question is
    /// whether removing strategy fusion overtakes PIMC's plateau once the tree
    /// is adequately sampled; this sweeps the budget up to find out.
    func testSelfPlayISMCTSBudget() async {
        for mult in [2, 4] {
            var d = MonteCarloAgent.Difficulty.normal
            d.research.useISMCTS = true
            d.research.ismctsBudgetMultiplier = mult
            let r = await AIArena.runSelfPlay(matches: 60, challenger: d,
                                              champion: .normal, baseSeed: 1)
            print("TREATMENT (IS-MCTS ×\(mult) budget vs normal):\n" + r.summary)
        }
    }

    /// 100-match confirmation of the promising IS-MCTS ×4 read (house rule:
    /// confirm a ≤60-match A/B at ≥100 before promoting). The ×1→×2→×4 sweep
    /// climbed 48→52→58 vs a 57% control at N=60; this checks the ×4 setting
    /// holds against a same-build 100-match PIMC control.
    func testSelfPlayISMCTSConfirm100() async {
        var d = MonteCarloAgent.Difficulty.normal
        d.research.useISMCTS = true
        d.research.ismctsBudgetMultiplier = 4
        let control = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal, 100):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 100, challenger: d,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (IS-MCTS ×4 vs normal, 100):\n" + r.summary)
    }

    /// Confirm IS-MCTS on the EXTREME profile before flipping the player-facing
    /// tier — it must hold with Extreme's full-width root (searchAllLegalMoves),
    /// deepInference, and exact-endgame gate-2 (which the IS-MCTS leaf keeps via
    /// max(rolloutExactTricks, exactEndgameTricks)). Extreme's base is 264 iters
    /// (44 × 6), so ×2 = 528 — past the ~320 that gave +8pp on Normal, with
    /// headroom for the wider root. Read TREATMENT vs the same-build Extreme
    /// PIMC control.
    func testSelfPlayISMCTSExtreme() async {
        var d = MonteCarloAgent.Difficulty.extreme
        d.research.useISMCTS = true
        d.research.ismctsBudgetMultiplier = 2
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .extreme,
                                                champion: .extreme, baseSeed: 1)
        print("CONTROL (extreme vs extreme):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: d,
                                          champion: .extreme, baseSeed: 1)
        print("TREATMENT (extreme+IS-MCTS ×2 vs extreme):\n" + r.summary)
    }

    /// Does gating the IS-MCTS ROOT to the narrow shortlist rescue the
    /// Extreme-neutral read? Concentrates 528 iters onto ~6 root moves
    /// (~88 visits/branch, the validated Normal regime) instead of spreading
    /// them over the full-legal root (~13 early). TREATMENT-ONLY: the PIMC
    /// Extreme control is unchanged by these default-off params — 67% (set
    /// 31%/42%) from `testSelfPlayISMCTSExtreme` on this build.
    func testSelfPlayISMCTSExtremeShortlistRoot() async {
        var d = MonteCarloAgent.Difficulty.extreme
        d.research.useISMCTS = true
        d.research.ismctsBudgetMultiplier = 2
        d.research.ismctsShortlistRoot = true
        let r = await AIArena.runSelfPlay(matches: 60, challenger: d,
                                          champion: .extreme, baseSeed: 1)
        print("TREATMENT (extreme+IS-MCTS ×2 shortlist-root vs extreme):\n" + r.summary)
    }

    /// A/B for DISTRIBUTION-AWARE bidding (`rolloutBidEval`): the challenger
    /// bids the `bidMakeProbability` quantile of rolled-out captured gross
    /// instead of the mean `expectedGross`, pricing set risk directly. Read
    /// TREATMENT vs the same-seed control. The set-rate line is the key
    /// secondary read — distribution-aware bidding should move the make-rate
    /// toward the ~85% (≈15% set) calibration target, even if self-play
    /// win-rate is insensitive (the bid-aggression lesson).
    func testSelfPlayRolloutBid() async {
        var d = MonteCarloAgent.Difficulty.normal
        d.rolloutBidEval = true
        let control = await AIArena.runSelfPlay(matches: 60, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 60, challenger: d,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (rolloutBidEval vs normal):\n" + r.summary)
    }

    /// A/B for BID-LEAN in the bid-deal sampler (`bidRolloutLean`): the rollout
    /// reads the auction (contested-auction opponents modeled as strong), the
    /// fix for the war over-bids seen in handlog 7. Control is no-lean vs
    /// no-lean (the pre-change baseline); treatment is lean vs no-lean. The
    /// key reads are the challenger's win-rate vs control AND its set-rate vs
    /// the no-lean champion's (bid-lean should bid contested hands more
    /// accurately → fewer sets).
    func testSelfPlayBidLean() async {
        var noLean = MonteCarloAgent.Difficulty.normal
        noLean.bidRolloutLean = false
        let control = await AIArena.runSelfPlay(matches: 100, challenger: noLean,
                                                champion: noLean, baseSeed: 1)
        print("CONTROL (no-lean vs no-lean):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                          champion: noLean, baseSeed: 1)
        print("TREATMENT (bid-lean vs no-lean):\n" + r.summary)
    }

    /// A/B for the AGGRESSION-MULTIPLIER DROP (`bidRolloutDropAggression`): the
    /// rollout figure already prices set risk, so multiplying its ceiling by
    /// 1.05 over-commits in wars. Shipped Normal is 1.00 (the drop is a no-op),
    /// so this exposes the effect on a fast Normal-speed profile given Hard's
    /// 1.05 aggression; the result transfers to Hard/Extreme (a bidding-ceiling
    /// change, orthogonal to trick-play depth). Champion keeps the multiplier;
    /// challenger drops it. The set-rate is the key read (dropping it should bid
    /// contested hands less aggressively → fewer sets).
    func testSelfPlayBidAggressionDrop() async {
        var base = MonteCarloAgent.Difficulty.normal
        base.bidAggression = 1.05
        var withMult = base
        withMult.bidRolloutDropAggression = false   // ceiling = safeContract × 1.05
        let control = await AIArena.runSelfPlay(matches: 100, challenger: withMult,
                                                champion: withMult, baseSeed: 1)
        print("CONTROL (1.05 multiplier applied, both):\n" + control.summary)
        var dropped = base
        dropped.bidRolloutDropAggression = true     // ceiling = safeContract
        let r = await AIArena.runSelfPlay(matches: 100, challenger: dropped,
                                          champion: withMult, baseSeed: 1)
        print("TREATMENT (aggression dropped vs 1.05 applied):\n" + r.summary)
    }

    /// `bidMakeProbability` sweep (treatment-only; the PIMC control is
    /// unchanged by these default-off params). Locates the make-threshold that
    /// lands the bid-population set-rate near the ~15% calibration target
    /// without surrendering win-rate.
    func testSelfPlayRolloutBidProbabilitySweep() async {
        for p in [0.45, 0.6, 0.75] {
            var d = MonteCarloAgent.Difficulty.normal
            d.rolloutBidEval = true
            d.bidMakeProbability = p
            let r = await AIArena.runSelfPlay(matches: 60, challenger: d,
                                              champion: .normal, baseSeed: 1)
            print("TREATMENT (rolloutBidEval p=\(p) vs normal):\n" + r.summary)
        }
    }

    /// 100-match confirmation of the best sweep point (p=0.45): same bid volume
    /// as the scalar control (49% share) but better selection (set 30%→23%) and
    /// +5pp at N=60. House rule: confirm a promising ≤60 read at ≥100 before
    /// promoting.
    func testSelfPlayRolloutBidConfirm100() async {
        var d = MonteCarloAgent.Difficulty.normal
        d.rolloutBidEval = true
        d.bidMakeProbability = 0.45
        let control = await AIArena.runSelfPlay(matches: 100, challenger: .normal,
                                                champion: .normal, baseSeed: 1)
        print("CONTROL (normal vs normal, 100):\n" + control.summary)
        let r = await AIArena.runSelfPlay(matches: 100, challenger: d,
                                          champion: .normal, baseSeed: 1)
        print("TREATMENT (rolloutBidEval p=0.45 vs normal, 100):\n" + r.summary)
    }

    /// Per-card calibration harvest: prints observed vs predicted realization
    /// rates for every money card in forced declarers' playing hands, plus the
    /// residual block. Not pass/fail — this is the instrument that retunes
    /// `keepProbability` / `offSuitWinProbability` / the non-money components
    /// from data instead of by hand. (Edit deals/baseSeed here per run — the
    /// clean-env wrapper in scripts/xcode-env.sh strips TEST_RUNNER_ vars, so
    /// there is no env override. ~2s per deal at .normal.)
    ///
    /// The fitted `.calibrated` tables came from 360 deals pooled across two
    /// seeds (1 and 100_001) measured against `.original`. The profile below
    /// now has `calibratedValuation` ON, so a re-run verifies the fit:
    /// predicted should track observed across cells.
    func testCardCalibrationHarvest() async {
        var profile = MonteCarloAgent.Difficulty.normal
        profile.calibratedValuation = true
        let r = await AIArena.runCardCalibration(deals: 120,
                                                 difficulty: profile,
                                                 baseSeed: 7)
        print(r.summary)
    }

    // MARK: - Traditional ladder monotonicity (§7.2)

    /// Proves the Traditional ladder is a REAL ladder: each higher rung beats
    /// the one below it head-to-head over seeded, seat-swapped self-play. The
    /// acceptance target is > ~55%; the hard assertion here is the weaker
    /// "the higher rung is not behind" (> 0.50) so the run flags only a genuine
    /// inversion/flatness, while the printed rates carry the calibration signal.
    /// Lives in AIArenaTests (arena mode) — it plays full matches and is slow.
    func testTraditionalLadderMonotonicity() async {
        let steps: [(String, MonteCarloAgent.Difficulty, MonteCarloAgent.Difficulty)] = [
            ("casual > novice",  .casual,  .novice),
            ("skilled > casual", .skilled, .casual),
            ("expert > skilled", .expert,  .skilled),
        ]
        for (label, higher, lower) in steps {
            let r = await AIArena.runSelfPlay(matches: 60, challenger: higher,
                                              champion: lower, baseSeed: 1)
            print("LADDER \(label):\n" + r.summary)
            XCTAssertGreaterThan(r.challengerWinRate, 0.50,
                                 "\(label): higher rung must not be behind "
                                 + "(got \(r.challengerWinRate))")
        }
    }
}
