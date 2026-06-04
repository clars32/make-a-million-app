//
//  AITacticsTests.swift
//  Make-a-MillionTests
//
//  Golden tactical positions. Each test encodes ONE strategic principle the
//  AI is expected to follow, as a hand-crafted full-information position, and
//  asserts the move chosen by `PlayoutPolicy.move(in:seat:)`.
//
//  Why target the playout and not `chooseMove`? The playout is the
//  deterministic, full-information tactical brain the MCTS calls thousands of
//  times to score candidates. If a principle is wrong HERE, every rollout
//  mis-values it and the search inherits the error. Testing it directly gives
//  a stable regression lock with no sampling noise — the exact thing the
//  hidden-information `chooseMove` path cannot offer.
//
//  Seating: team 0 = seats 0 & 2, team 1 = seats 1 & 3 (partners opposite).
//  "Me" is always seat 0 in these positions.
//

import XCTest
@testable import Make_A_Million_Mobile

final class AITacticsTests: XCTestCase {

    // MARK: - Position builder

    /// Build a mid-trick, full-information `GameState` directly via the
    /// memberwise initializer (the same one `AIWorld.rebuild` uses). Misdeal
    /// is disabled so no rollout machinery can redeal underneath us.
    private func trickState(hands: [PlayerID: [Card]],
                            trump: CardColor,
                            leader: PlayerID,
                            onTable: [(PlayerID, Card)],
                            toAct: PlayerID,
                            highBidder: PlayerID = PlayerID(1)) -> GameState {
        let plays = onTable.map { PlayedCard(player: $0.0, card: $0.1) }
        return GameState(
            dealSeed: 0,
            dealer: PlayerID(0),
            hands: hands,
            widow: [],
            phase: .trickPlay,
            toAct: toAct,
            highBid: 200_000,
            highBidder: highBidder,
            passed: [],
            bidHistory: [],
            trump: trump,
            misdealRule: .disabled,
            endgameRule: .standard,
            currentTrick: Trick(leader: leader, plays: plays),
            completedTricks: [],
            capturedByTeam: [0: [], 1: []],
            matchScore: [0: 0, 1: 0],
            dealtHands: [:],
            dealtWidow: []
        )
    }

    private func P(_ i: Int) -> PlayerID { PlayerID(i) }
    private func y(_ r: Card.Rank) -> Card { .colored(.yellow, r) }
    private func blk(_ r: Card.Rank) -> Card { .colored(.black, r) }
    private func grn(_ r: Card.Rank) -> Card { .colored(.green, r) }

    // MARK: - B1: do not feed money to a trick a loose Bear will zero

    func testDoesNotDumpMoneyWhenOpponentCanBear() {
        // Partner (seat 2) is winning the $40k yellow. I (seat 0) must follow
        // yellow and hold the $30k and the 2. Seat 1 (opponent, yet to play)
        // is void in yellow and holds the Bear — they can legally cancel this
        // trick. I must NOT add my $30k; shed the 2 instead.
        let hands: [PlayerID: [Card]] = [
            P(0): [y(.money30k), y(.two)],
            P(1): [.bear, blk(.one), blk(.two)],     // void yellow, holds Bear
            P(2): [grn(.one)],
            P(3): [grn(.two)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(2),
            onTable: [(P(2), y(.money40k)), (P(3), y(.one))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(y(.two)))
    }

    func testDumpsMoneyOntoPartnerWhenNoBearThreat() {
        // Same shape, but seat 1 has no Bear (and no trump / no higher yellow),
        // so partner's win is genuinely safe. I'm void in yellow, so I dump my
        // highest NON-controller money (the $10k black) while keeping the $40k
        // black as a future controller.
        let hands: [PlayerID: [Card]] = [
            P(0): [blk(.money40k), blk(.money10k), grn(.one)],   // void yellow
            P(1): [grn(.two), grn(.three)],                      // no Bear/trump
            P(2): [grn(.four)],
            P(3): [grn(.seven)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(2),
            onTable: [(P(2), y(.money40k)), (P(3), y(.one))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(blk(.money10k)))
    }

    // MARK: - B2: bank money when last to play and the win is certain

    func testBanksMoneyAsLastPlayerInsteadOfCheapWinner() {
        // I am last to play and can win with EITHER the 11 (non-money) or the
        // $30k. The cheap-winner instinct would play the 11 and strand the
        // $30k; banking is correct because no one plays after me.
        let hands: [PlayerID: [Card]] = [
            P(0): [y(.money30k), y(.eleven)],
            P(1): [grn(.one)],
            P(2): [grn(.two)],
            P(3): [grn(.three)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(1),
            onTable: [(P(1), y(.money10k)), (P(2), y(.three)), (P(3), y(.four))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(y(.money30k)))
    }

    // MARK: - #4: lead the boss money card to bank it

    func testLeadsBossMoneyOfAVirginColor() {
        // On lead, not the declarer. I hold the $40k of yellow (top of color,
        // un-led) — cash it now rather than dribbling low cards.
        let hands: [PlayerID: [Card]] = [
            P(0): [y(.money40k), grn(.two), grn(.one)],
            P(1): [blk(.one), blk(.two), blk(.three)],
            P(2): [blk(.four), blk(.seven), blk(.eight)],
            P(3): [grn(.three), grn(.four), grn(.seven)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(0),
            onTable: [], toAct: P(0), highBidder: P(1))   // I'm not declarer
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(y(.money40k)))
    }

    // MARK: - B3: give a winning opponent the least possible

    func testStarvesWinningOpponentWithCheapNonMoney() {
        // Opponent (seat 3) is winning the $40k yellow and I cannot beat it.
        // I must follow yellow with the $30k or the 2 — give up the 2, never
        // feed my $30k into their trick.
        let hands: [PlayerID: [Card]] = [
            P(0): [y(.money30k), y(.two)],
            P(1): [grn(.one)],
            P(2): [grn(.two)],
            P(3): [grn(.three)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(2),
            onTable: [(P(2), y(.one)), (P(3), y(.money40k))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(y(.two)))
    }

    func testBearsAnOpponentsBigMoneyTrick() {
        // Opponent (seat 3) is winning a $40k trick; I'm void in yellow and
        // hold the Bear — cancel the trick to zero.
        let hands: [PlayerID: [Card]] = [
            P(0): [.bear, grn(.one)],
            P(1): [grn(.two)],
            P(2): [grn(.three)],
            P(3): [grn(.four)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(2),
            onTable: [(P(2), y(.one)), (P(3), y(.money40k))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(.bear))
    }
}
