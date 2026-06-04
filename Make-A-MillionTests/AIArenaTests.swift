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
}