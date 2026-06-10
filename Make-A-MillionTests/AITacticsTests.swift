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

    // MARK: - Bear already on the table: the trick is worth $0

    func testDoesNotBankMoneyIntoAnAlreadyBearedTrick() {
        // The Bear is already on the table (seat 3), so this trick is worth $0.
        // I am last to play and COULD win it with my $30k — but banking money
        // into a Beared trick just burns it. Shed the 2 and keep the $30k.
        let hands: [PlayerID: [Card]] = [
            P(0): [y(.money30k), y(.two)],
            P(1): [grn(.one)],
            P(2): [grn(.two)],
            P(3): [grn(.three)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(1),
            onTable: [(P(1), y(.money10k)), (P(2), y(.three)), (P(3), .bear)],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(y(.two)))
    }

    func testDoesNotDumpMoneyOntoPartnersAlreadyBearedTrick() {
        // Partner (seat 2) "wins" the trick by rank, but an opponent already
        // dropped the Bear, so it is worth $0. Adding my $10k is wasted — shed
        // the low card and keep the money for a live trick.
        let hands: [PlayerID: [Card]] = [
            P(0): [blk(.money10k), grn(.one)],   // void in yellow
            P(1): [grn(.two), grn(.three)],
            P(2): [grn(.four)],
            P(3): [grn(.seven)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(2),
            onTable: [(P(2), y(.money40k)), (P(3), .bear)],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)), .play(grn(.one)))
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

    // MARK: - Bull endgame: escape the forced final-trick double
    //
    // The Bull only ever helps a trick OUR side wins, and it can only be
    // played when its holder cannot follow (or as the last card). Carried to
    // the last card it is FORCED onto/into the final trick and doubles it for
    // whoever wins — a repeated six-figure leak in real hands. These lock the
    // `specialEscape` rollout rules (and the legacy flag-off behaviour, so the
    // stable `move(in:seat:)` golden API is unchanged).

    func testShedsBullOnWorthlessOpponentTrickLate() {
        // Late in the hand (≤6 cards left), an opponent (seat 3) is winning a
        // $0 pot and I cannot follow. I could ruff with low trump — but the
        // trick is worthless, and I'm carrying the Bull. With specialEscape,
        // ditch the Bull now for free (doubling $0 costs nothing) instead of
        // winning a nothing trick and staying trapped.
        let hands: [PlayerID: [Card]] = [
            P(0): [.bull, .colored(.red, .four), .colored(.red, .seven)],
            P(1): [y(.money40k), grn(.one)],
            P(2): [grn(.two), grn(.three)],
            P(3): [y(.money30k), grn(.four)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(1),
            onTable: [(P(1), y(.one)), (P(2), y(.two)), (P(3), y(.three))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0), specialEscape: true),
                       .play(.bull))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)),
                       .play(.colored(.red, .four)),
                       "legacy path (flag off) still ruffs cheaply")
    }

    func testSpendsBullAndKeepsBearWhenTrappedWithBoth() {
        // Trapped holding exactly BER+BUL. An opponent is winning a small $5k
        // pot while the other hands still hold $70k that the remaining tricks
        // will decide. The shed comparator's instinct (Bear is "cheap", Bull
        // is "costly") spends the Bear here — leaving the Bull to be FORCED
        // onto the big final trick, doubling it for the opponents. Correct
        // sequencing is the reverse: pay the small double now, keep the Bear
        // to cancel the big trick.
        let hands: [PlayerID: [Card]] = [
            P(0): [.bull, .bear],
            P(1): [y(.money40k), y(.money30k)],   // opponents' big money still live
            P(2): [grn(.one), grn(.two)],
            P(3): [y(.two)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(3),
            onTable: [(P(3), y(.money5k))],
            toAct: P(0))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0), specialEscape: true),
                       .play(.bull))
        XCTAssertEqual(PlayoutPolicy.move(in: state, seat: P(0)),
                       .play(.bear),
                       "legacy comparator sheds the Bear first — locked as the flag-off behaviour")
    }

    func testShortlistRescuesDroppedSpecialFromSingleton() {
        // Agent-level invariant (no MCTS in the loop): when the heuristic
        // shortlist narrows a Bull/Bear-bearing legal set to a single card,
        // the dropped special must be appended so the search — not a one-line
        // comparator — decides the sequencing. Position: BER+BUL are my whole
        // hand and the pot is big enough ($15k) that only the Bear survives
        // the heuristic branches; the rescue must re-add the Bull.
        let hands: [PlayerID: [Card]] = [
            P(0): [.bull, .bear],
            P(1): [y(.money40k), y(.money30k)],
            P(2): [grn(.one), grn(.two)],
            P(3): [y(.two)],
        ]
        let state = trickState(
            hands: hands, trump: .red, leader: P(3),
            onTable: [(P(3), y(.money15k))],
            toAct: P(0))
        let view = state.view(for: P(0))
        let agent = MonteCarloAgent(name: "T", difficulty: .normal, seed: 1)
        let shortlist = agent.trickShortlist(
            view: view, legal: view.legalMoves,
            inference: TableInference(view: view))
        XCTAssertTrue(shortlist.contains(.play(.bear)),
                      "Bear (cancel the pot) must be a candidate")
        XCTAssertTrue(shortlist.contains(.play(.bull)),
                      "rescued Bull must reach MCTS — sequencing the specials is the search's call")
    }

    // MARK: - Near-tie preference ordering (the decideTrickPlay tiebreak)
    //
    // When MCTS means are within noise of each other, the dollars printed on
    // the card decide — they are certain, the means are not. Full-width
    // search made this matter: dominated money-donations now reach MCTS, and
    // a money-blind tie once donated a G$40 over a G$5 in real play.

    func testTiePreferenceStarvesOpponentBoundTricks() {
        // Feeding a trick the opponents own: less money strictly preferred.
        let cheap = MonteCarloAgent.tiePreference(grn(.money5k), trump: .red,
                                                  dumpToPartner: false, following: true)
        let dear = MonteCarloAgent.tiePreference(grn(.money40k), trump: .red,
                                                 dumpToPartner: false, following: true)
        XCTAssertTrue(cheap < dear, "tied shed onto opponents must give the $5k, never the $40k")
        // And a free card beats any money at all.
        let free = MonteCarloAgent.tiePreference(grn(.one), trump: .red,
                                                 dumpToPartner: false, following: true)
        XCTAssertTrue(free < cheap)
    }

    func testTiePreferenceFeedsPartnerBoundTricks() {
        // Partner safely owns the trick: MORE money preferred (the dump).
        let dump = MonteCarloAgent.tiePreference(y(.money15k), trump: .red,
                                                 dumpToPartner: true, following: true)
        let hold = MonteCarloAgent.tiePreference(grn(.seven), trump: .red,
                                                 dumpToPartner: true, following: true)
        XCTAssertTrue(dump < hold, "tied choice on partner's safe trick must prefer the money dump")
    }

    func testTiePreferenceNeverSpendsSpecialsOrTigerOnATie() {
        let low = MonteCarloAgent.tiePreference(grn(.one), trump: .red,
                                                dumpToPartner: false, following: true)
        let bear = MonteCarloAgent.tiePreference(.bear, trump: .red,
                                                 dumpToPartner: false, following: true)
        let tiger = MonteCarloAgent.tiePreference(.tiger, trump: .red,
                                                  dumpToPartner: false, following: true)
        XCTAssertTrue(low < bear, "specials outrank any plain card in a tie")
        XCTAssertTrue(bear < tiger, "the Tiger is the last card a tie should ever spend")
    }

    func testTiePreferenceConservesTrumpAfterMoney() {
        // Equal money (none): off-suit shed preferred over breaking trump.
        let offSuit = MonteCarloAgent.tiePreference(grn(.one), trump: .red,
                                                    dumpToPartner: false, following: true)
        let trumpLow = MonteCarloAgent.tiePreference(.colored(.red, .four), trump: .red,
                                                     dumpToPartner: false, following: true)
        XCTAssertTrue(offSuit < trumpLow)
    }
}
