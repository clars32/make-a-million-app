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
        await AIArena.traceOneHand(difficulty: .medium, dealSeed: 1)
    }

    /// Step 2. Small and quick — confirms the arena loop itself works and
    /// gives an early read before committing to the long run.
    func testArenaSmall() async {
        let r = await AIArena.run(matches: 8, difficulty: .medium, baseSeed: 1)
        print(r.summary)
    }

    /// Step 3. The real verdict. This is the number to send back. It may take
    /// a little while — many hands × samples × rollouts — so run it on its
    /// own and let it finish.
    func testArenaVerdict() async {
        let r = await AIArena.run(matches: 30, difficulty: .medium, baseSeed: 1)
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
        let r = await AIArena.runSelfPlay(matches: 20, challenger: .medium,
                                          champion: .medium, baseSeed: 1)
        print(r.summary)
    }

    /// Regression guard for the bid calibration: the new default `.medium`
    /// against the previous, more conservative profile. Should be win-rate
    /// neutral, take a few more bids, and not raise the set-rate.
    func testSelfPlayBidCalibration() async {
        // New default `.medium` (challenger) vs the previous, more conservative
        // bid profile (champion). Confirms the calibration is win-rate neutral
        // and keeps the set-rate bounded.
        var oldProfile = MonteCarloAgent.Difficulty.medium
        oldProfile.bidAggression = 0.92
        oldProfile.partnerRespect = 0.85
        let r = await AIArena.runSelfPlay(matches: 20, challenger: .medium,
                                          champion: oldProfile, baseSeed: 1)
        print(r.summary)
    }

    /// A/B for bid-inference in the world sampler: challenger reads the
    /// auction (bidLeanStrength 1.0), champion samples uniformly (0.0).
    /// Expect neutral-or-better win-rate; the feature also makes play more
    /// human-like (it stops crediting passers with monster hands).
    func testSelfPlayBidInference() async {
        var noInference = MonteCarloAgent.Difficulty.medium
        noInference.bidLeanStrength = 0.0
        let r = await AIArena.runSelfPlay(matches: 30, challenger: .medium,
                                          champion: noInference, baseSeed: 1)
        print(r.summary)
    }

    /// Opponent-free calibration: is the evaluator under-valuing hands (i.e.
    /// passing makeable ones)? Forces each seat to declare at the floor and
    /// compares estimate vs realized gross. Prints the calibration curve.
    func testBidCalibration() async {
        let r = await AIArena.runBidCalibration(deals: 25, difficulty: .medium,
                                                baseSeed: 1)
        print(r.summary)
    }
}