//
//  TableInferenceTests.swift
//  Make-A-MillionTests
//
//  Deterministic checks on the heuristic table-read deductions. Built from a
//  hand-constructed PlayerView (no MCTS), so they assert exact facts.
//

import XCTest
@testable import Make_A_Million_Mobile

final class TableInferenceTests: XCTestCase {

    private func Y(_ r: Card.Rank) -> Card { .colored(.yellow, r) }

    /// A mid-hand view where YELLOW is fully exhausted: twelve yellows have
    /// been played (three all-yellow tricks, so nobody ever failed to follow)
    /// and I hold the thirteenth (Y$40). Trump is black; my hand is otherwise
    /// black/red so black is NOT exhausted.
    private func exhaustedYellowView() -> PlayerView {
        let me = PlayerID(0)
        let declarer = PlayerID(1)
        let playedYellows: [Card] = [
            Y(.one), Y(.two), Y(.three), Y(.four),
            Y(.money5k), Y(.seven), Y(.eight), Y(.nine),
            Y(.money10k), Y(.eleven), Y(.money15k), Y(.money30k)
        ]
        func trick(_ four: ArraySlice<Card>) -> CompletedTrickInfo {
            let seats = [PlayerID(0), PlayerID(1), PlayerID(2), PlayerID(3)]
            let plays = zip(seats, four).map { PlayedCard(player: $0.0, card: $0.1) }
            return CompletedTrickInfo(leader: PlayerID(0), plays: plays,
                                      winner: PlayerID(0), value: 0)
        }
        let tricks = [
            trick(playedYellows[0..<4]),
            trick(playedYellows[4..<8]),
            trick(playedYellows[8..<12]),
        ]
        let myHand: [Card] = [
            Y(.money40k),
            .colored(.black, .money40k), .colored(.black, .money30k),
            .colored(.black, .money15k), .colored(.black, .eleven),
            .colored(.black, .nine), .colored(.black, .eight),
            .colored(.black, .seven), .colored(.black, .money5k),
            .colored(.red, .money40k), .colored(.red, .money30k),
            .colored(.red, .money15k), .colored(.red, .eleven),
        ]
        return PlayerView(
            me: me, myHand: myHand, phase: .trickPlay, toAct: me,
            trump: .black, highBid: 200_000, highBidder: declarer,
            passed: [], opener: declarer, bidHistory: [], widow: nil,
            discardAnnouncement: nil,
            currentTrick: nil, completedTrickCount: tricks.count,
            completedTricks: tricks, matchScore: [0: 0, 1: 0], legalMoves: [])
    }

    /// With deep inference on, every other seat is void in the exhausted suit,
    /// and NOT void in a suit that still has cards out.
    func testDeepInferenceMarksCountExhaustionVoids() {
        let view = exhaustedYellowView()
        let inf = TableInference(view: view, inference: .deep)
        for seat in [PlayerID(1), PlayerID(2), PlayerID(3)] {
            XCTAssertTrue(inf.isKnownVoid(seat, in: .yellow),
                          "seat \(seat.raw) must be void in exhausted yellow")
            XCTAssertFalse(inf.isKnownVoid(seat, in: .black),
                           "black is not exhausted, so no void should be inferred")
        }
    }

    /// Control: without deep inference, the same view yields no yellow void —
    /// nobody failed to follow (all three tricks were pure yellow).
    func testWithoutDeepInferenceNoCountVoids() {
        let view = exhaustedYellowView()
        let inf = TableInference(view: view, inference: .counting)
        for seat in [PlayerID(1), PlayerID(2), PlayerID(3)] {
            XCTAssertFalse(inf.isKnownVoid(seat, in: .yellow),
                           "seat \(seat.raw) should not be flagged void without deep inference")
        }
    }

    /// The discard announcement is public counting information: a revealed
    /// money discard is DEAD (not still "out", and no longer locked into the
    /// declarer's hand), and the announced trump count comes straight off
    /// "trump still out".
    func testDiscardAnnouncementSharpensCounting() {
        // I'm South holding all 13 yellows (zero trump). Trump is black. The
        // declarer's forced discard was announced as 2 trump plus the shown
        // red $40k (which had been dealt to the widow).
        let me = PlayerID(0)
        let declarer = PlayerID(1)
        let myHand: [Card] = Card.Rank.allCases.map { .colored(.yellow, $0) }
        let revealed: Card = .colored(.red, .money40k)
        let widow: [Card] = [revealed, .colored(.black, .one), .colored(.green, .two)]
        let view = PlayerView(
            me: me, myHand: myHand, phase: .trickPlay, toAct: me,
            trump: .black, highBid: 200_000, highBidder: declarer,
            passed: [], opener: declarer, bidHistory: [], widow: widow,
            discardAnnouncement: DiscardAnnouncement(trumpCount: 2,
                                                     moneyCards: [revealed]),
            currentTrick: nil, completedTrickCount: 0, completedTricks: [],
            matchScore: [0: 0, 1: 0], legalMoves: [])
        let inf = TableInference(view: view)

        // The revealed $40k is dead: it is NOT a known declarer holding…
        XCTAssertFalse(inf.knownDeclarerHoldings().contains(revealed),
                       "a revealed money discard must not stay locked in the declarer")
        // …and no longer the highest red still out — that is now the $30k.
        XCTAssertEqual(inf.highestOutInColor(.red), .colored(.red, .money30k))
        // Trump accounting: 13 black + Tiger unseen, none in my hand, minus
        // the 2 announced face-down trump = 12 still in actual hands.
        XCTAssertEqual(inf.trumpStillOutInOpponentsAndPartner, 12)
    }
}
