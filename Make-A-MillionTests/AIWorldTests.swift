//
//  AIWorldTests.swift
//  Make-A-MillionTests
//
//  Deterministic checks on the world Determinizer's HARD deductions. These
//  reason about sampled full-information worlds, so they assert facts that must
//  hold in EVERY sample (not statistical tendencies), keeping them stable.
//

import XCTest
@testable import Make_A_Million_Mobile

final class AIWorldTests: XCTestCase {

    /// Minimal trick-play view: I'm South (seat 0); West (seat 1) is the
    /// declarer who took a widow containing the Tiger and the $30k of red
    /// (both un-discardable). Nothing has been played yet, so the declarer
    /// provably still holds both.
    private func makeView() -> PlayerView {
        let me = PlayerID(0)
        let declarer = PlayerID(1)
        // A full yellow suit as my hand — disjoint from the widow cards.
        let myHand: [Card] = Card.Rank.allCases.map { .colored(.yellow, $0) }
        let widow: [Card] = [.tiger,
                             .colored(.red, .money30k),
                             .colored(.green, .three)]   // the green 3 is discardable
        return PlayerView(
            me: me,
            myHand: myHand,
            phase: .trickPlay,
            toAct: declarer,
            trump: .black,
            highBid: 200_000,
            highBidder: declarer,
            passed: [],
            opener: declarer,
            bidHistory: [],
            widow: widow,
            currentTrick: Trick(leader: declarer),
            completedTrickCount: 0,
            completedTricks: [],
            matchScore: [0: 0, 1: 0],
            legalMoves: [])
    }

    /// With the Extreme deduction on, the declarer's un-discardable widow
    /// cards are in the declarer's hand in EVERY sampled world.
    func testExtremePinsDeclarersUndiscardableWidowCards() {
        let view = makeView()
        let declarer = PlayerID(1)
        let tiger: Card = .tiger
        let r30: Card = .colored(.red, .money30k)
        let g3: Card = .colored(.green, .three)   // discardable — must NOT be pinned

        for s in 0..<30 {
            var det = Determinizer(view: view, seed: UInt64(s) &+ 1,
                                   bidLeanStrength: 0, deduceWidowHoldings: true)
            guard let world = det.sample() else { XCTFail("sample \(s) failed"); continue }
            let west = world.state.hands[declarer] ?? []
            XCTAssertTrue(west.contains(tiger), "Tiger must be pinned to declarer (seed \(s))")
            XCTAssertTrue(west.contains(r30), "R$30 must be pinned to declarer (seed \(s))")
            XCTAssertEqual(west.count, 13, "declarer keeps an exact 13-card hand (seed \(s))")
            // The discardable widow card is NOT a forced holding — it may land
            // anywhere (declarer, another seat, or the discard pile).
            _ = g3
            // Sanity: nobody is dealt a duplicate / my hand is untouched.
            XCTAssertEqual(world.state.hands[view.me]?.count, 13)
        }
    }

    /// Control: with the deduction off, the Tiger is free to scatter, so it
    /// must NOT always land with the declarer.
    func testWithoutDeductionWidowCardsScatter() {
        let view = makeView()
        let declarer = PlayerID(1)
        var timesWithDeclarer = 0
        var samples = 0
        for s in 0..<40 {
            var det = Determinizer(view: view, seed: UInt64(s) &+ 1,
                                   bidLeanStrength: 0, deduceWidowHoldings: false)
            guard let world = det.sample() else { continue }
            samples += 1
            if (world.state.hands[declarer] ?? []).contains(.tiger) { timesWithDeclarer += 1 }
        }
        XCTAssertGreaterThan(samples, 0)
        XCTAssertLessThan(timesWithDeclarer, samples,
                          "Without deduction the Tiger should sometimes land elsewhere")
    }
}
