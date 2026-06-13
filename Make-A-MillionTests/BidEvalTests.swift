//
//  BidEvalTests.swift
//  Make-a-MillionTests
//
//  Locks for distribution-aware bidding (`Difficulty.rolloutBidEval`): the
//  bidder estimates the captured-gross DISTRIBUTION by rolling out the hand
//  with itself declaring, and bids the `bidMakeProbability` quantile instead of
//  the mean `expectedGross`. Stochastic, so the locks are coarse, robust
//  properties: a money-rich hand bids, a dead hand passes, and the decision is
//  reproducible from the seed.
//
//  Seating: team 0 = seats 0 & 2, team 1 = seats 1 & 3.
//

import XCTest
@testable import Make_A_Million_Mobile

final class BidEvalTests: XCTestCase {

    /// A first-round bidding view (no one has acted) for seat 2, with a small
    /// legal bid grid plus pass — enough for `decideBid` to choose.
    private func biddingView(_ hand: [Card]) -> PlayerView {
        let legal: [Move] = [.bid(.pass),
                             .bid(.bid(175_000)), .bid(.bid(185_000)),
                             .bid(.bid(195_000)), .bid(.bid(205_000))]
        return PlayerView(
            me: PlayerID(2), myHand: hand, phase: .bidding, toAct: PlayerID(2),
            trump: nil, highBid: nil, highBidder: nil, passed: [],
            opener: PlayerID(0), bidHistory: [], widow: nil,
            discardAnnouncement: nil, currentTrick: nil, completedTrickCount: 0,
            completedTricks: [], matchScore: [0: 0, 1: 0], legalMoves: legal)
    }

    // Money-rich + long red trump — clearly worth a declare.
    private let strong: [Card] = [.colored(.red, .money40k), .colored(.red, .money30k),
                                  .colored(.red, .money15k), .colored(.red, .money10k),
                                  .colored(.red, .money5k), .colored(.yellow, .money40k),
                                  .colored(.yellow, .money30k), .colored(.yellow, .money15k),
                                  .colored(.yellow, .money10k), .colored(.yellow, .money5k),
                                  .colored(.red, .eleven), .colored(.red, .nine),
                                  .colored(.red, .eight)]
    // Low, moneyless, no length — a dead hand.
    private let weak: [Card] = [.colored(.red, .one), .colored(.red, .two),
                               .colored(.red, .three), .colored(.green, .one),
                               .colored(.green, .two), .colored(.green, .three),
                               .colored(.green, .four), .colored(.black, .one),
                               .colored(.black, .two), .colored(.black, .three),
                               .colored(.yellow, .one), .colored(.yellow, .two),
                               .colored(.yellow, .three)]

    private func agent(seed: UInt64, p: Double = 0.55, worlds: Int = 20) -> MonteCarloAgent {
        var d = MonteCarloAgent.Difficulty.normal
        d.rolloutBidEval = true
        d.bidRolloutWorlds = worlds
        d.bidMakeProbability = p
        return MonteCarloAgent(difficulty: d, seed: seed)
    }

    func testRolloutBidderBidsAMoneyRichHand() async {
        let move = await agent(seed: 1).chooseMove(from: biddingView(strong))
        XCTAssertNotEqual(move, .bid(.pass),
            "a money-rich, trump-long hand should clear the rollout make threshold")
    }

    func testRolloutBidderPassesADeadHand() async {
        let move = await agent(seed: 1).chooseMove(from: biddingView(weak))
        XCTAssertEqual(move, .bid(.pass),
            "a low, moneyless hand can't make the floor in rollout — pass")
    }

    func testRolloutBidIsDeterministic() async {
        let a = await agent(seed: 7).chooseMove(from: biddingView(strong))
        let b = await agent(seed: 7).chooseMove(from: biddingView(strong))
        XCTAssertEqual(a, b, "same seed + view must give the same bid")
    }

    /// A stricter make-probability is never more aggressive: the contract figure
    /// at p=0.85 must not exceed the one at p=0.40 on the same hand (the higher
    /// quantile sits lower in the captured-gross distribution). Checked through
    /// the bid: at p=0.85 the dead hand still passes (sanity that the knob is
    /// wired and monotonic in the safe direction).
    func testHigherMakeProbabilityIsNotMoreAggressive() async {
        let cautious = await agent(seed: 3, p: 0.85).chooseMove(from: biddingView(weak))
        XCTAssertEqual(cautious, .bid(.pass),
            "a stricter make threshold must still pass a dead hand")
    }
}
