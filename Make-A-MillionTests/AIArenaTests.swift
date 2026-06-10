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
    /// `Difficulty.declarerTrumpBias`). Re-run this after a refinement (bias
    /// only low trump, or reduce `bidLeanStrength` alongside).
    func testSelfPlayTrumpShape() async {
        var withShape = MonteCarloAgent.Difficulty.normal
        withShape.declarerTrumpBias = 0.4
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
        withPull.rolloutCommandingPull = true
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
        withEscape.rolloutSpecialEscape = true
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

    /// Probe for the (PARKED) `matchWinWeight` lever (match-aware trick-play
    /// objective: utility = teamNet + W·P(win match)). Expect any edge to
    /// show as a MATCH-win-rate gain (the lever deliberately trades
    /// hand-dollars for match equity near the $1M line and on set/made knife
    /// edges). Read TREATMENT against the same-seed control, not 50%.
    /// Measured paired at 60 / baseSeed 1, weight 400k: control 63% →
    /// treatment 63% (challenger set 15%→14%) — NEUTRAL, so parked at 0 (soft
    /// priors aren't promoted on neutral reads). Caveat: match context is
    /// live in only a minority of hands, so this all-phases A/B has little
    /// power; a fair re-test needs a conditional instrument (e.g. win rate
    /// given a team reaches $700k first).
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
}