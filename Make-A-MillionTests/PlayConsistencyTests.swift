//
//  PlayConsistencyTests.swift
//  Make-a-MillionTests
//
//  Correctness locks for play-consistency world filtering
//  (`Difficulty.research.playConsistencyFilter` → `Determinizer.isConsistentWithPlay`).
//
//  The filter replays the public trick history through the ENGINE in a sampled
//  world and REJECTS the world if it forces a hidden seat to have made a
//  provably-dominated play. The locks come in two directions:
//
//    • REJECT — a world that requires a dominated play (money/Bull donated into
//      a certain loss when a throwaway was legal; the Bear declined on a fat
//      certain loss) is thrown out.
//    • ACCEPT (no false positives) — a world where the same play was FORCED
//      (no cheap alternative), where the seat was feeding its own partner, or
//      where the seat could still win the trick, is kept. This direction is the
//      one that protects the search from over-pruning, so it gets the most
//      cases.
//
//  Seating: team 0 = seats 0 & 2, team 1 = seats 1 & 3.
//

import XCTest
@testable import Make_A_Million_Mobile

final class PlayConsistencyTests: XCTestCase {

    // MARK: - Helpers

    private func P(_ i: Int) -> PlayerID { PlayerID(i) }
    private func grn(_ r: Card.Rank) -> Card { .colored(.green, r) }
    private func ylw(_ r: Card.Rank) -> Card { .colored(.yellow, r) }
    private func blk(_ r: Card.Rank) -> Card { .colored(.black, r) }
    private func red(_ r: Card.Rank) -> Card { .colored(.red, r) }

    /// One completed trick from a leader and the ordered (seat, card) plays.
    /// Winner and settled value come from the engine, so the fixture can't
    /// silently disagree with the rules it is testing against.
    private func trick(leader: PlayerID, _ plays: [(PlayerID, Card)],
                       trump: CardColor) -> CompletedTrickInfo {
        let pcs = plays.map { PlayedCard(player: $0.0, card: $0.1) }
        let t = Trick(leader: leader, plays: pcs)
        return CompletedTrickInfo(leader: leader, plays: pcs,
                                  winner: GameState.trickWinner(t, trump: trump),
                                  value: GameState.trickValue(t))
    }

    /// A trick-play view for seat `me`, carrying `completed` as the public
    /// history. The next leader (winner of the last trick) is on lead with an
    /// empty current trick — the filter reads history from both.
    private func view(me: PlayerID, trump: CardColor, myHand: [Card],
                      completed: [CompletedTrickInfo]) -> PlayerView {
        let nextLeader = completed.last?.winner ?? me
        return PlayerView(
            me: me, myHand: myHand, phase: .trickPlay, toAct: nextLeader,
            trump: trump, highBid: 200_000, highBidder: P(1),
            passed: [], opener: P(1), bidHistory: [], widow: nil,
            discardAnnouncement: nil,
            currentTrick: Trick(leader: nextLeader),
            completedTrickCount: completed.count, completedTricks: completed,
            matchScore: [0: 0, 1: 0], legalMoves: [])
    }

    /// An `AIWorld` whose seats hold exactly `remaining` right now. Only
    /// `state.hands` is read by the filter; the rest is a valid placeholder.
    private func world(remaining: [PlayerID: [Card]], me: PlayerID,
                       trump: CardColor) -> AIWorld {
        let st = GameState(
            dealSeed: 0, dealer: P(0), hands: remaining, widow: [],
            phase: .trickPlay, toAct: me, highBid: 200_000, highBidder: P(1),
            passed: [], bidHistory: [], trump: trump, discardAnnouncement: nil,
            misdealRule: .disabled, endgameRule: .standard,
            currentTrick: nil, completedTricks: [], capturedByTeam: [0: [], 1: []],
            matchScore: [0: 0, 1: 0], dealtHands: [:], dealtWidow: [])
        return AIWorld(state: st, me: me)
    }

    /// The filter with BOTH consistency checks enabled (the locks below assert
    /// each check's behaviour; per-check A/B happens in the arena).
    private func filter(_ view: PlayerView) -> Determinizer {
        Determinizer(view: view, seed: 1,
                     filterDominatedDonation: true, filterBearDecline: true)
    }

    // MARK: - (A) Money / Bull donation

    /// P1 (team 1), last to a green trick team 0 has already won, dumps the
    /// yellow $10k off-suit. A world that also hands P1 a worthless black 2 is
    /// impossible (no one donates with a throwaway in hand); a world where P1
    /// held only money is the FORCED dump and must be kept.
    func testRejectsMoneyDonationWithThrowawayAvailable() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.money10k))],
                       trump: .red)
        XCTAssertEqual(tr.winner, P(2))   // team 0 took it
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)

        let dominated = world(remaining: [P(0): [], P(1): [blk(.two)],
                                          P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertFalse(f.isConsistentWithPlay(dominated),
            "P1 donating $10k with a black 2 in hand is a dominated play → reject")

        let forced = world(remaining: [P(0): [], P(1): [ylw(.money5k)],
                                       P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(forced),
            "P1 holding only money had no throwaway → the dump was forced → keep")
    }

    /// The soft play-history weight is intentionally gentler than the hard
    /// filter: a suspicious large-money dump is downweighted, not deleted.
    func testSoftPlayHistoryWeightDownweightsButKeepsSuspiciousDonation() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.money30k))],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let det = Determinizer(view: v, seed: 1)

        let suspicious = world(remaining: [P(0): [], P(1): [blk(.two)],
                                           P(2): [], P(3): []], me: me, trump: .red)
        let forced = world(remaining: [P(0): [], P(1): [ylw(.money5k)],
                                       P(2): [], P(3): []], me: me, trump: .red)

        let suspiciousWeight = det.playHistoryWeight(suspicious, strength: 1.0)
        let forcedWeight = det.playHistoryWeight(forced, strength: 1.0)

        XCTAssertGreaterThan(suspiciousWeight, 0,
                             "soft weighting must never reject a legal world outright")
        XCTAssertLessThan(suspiciousWeight, forcedWeight,
                          "a dump with a cheap throwaway should be less likely than a forced money dump")
    }

    /// The Bull DOUBLES the captured money, so dropping it on a trick the
    /// opponents are certainly taking is at least as dominated as donating cash.
    func testRejectsBullDonationWithThrowawayAvailable() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), .bull)],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let dominated = world(remaining: [P(0): [], P(1): [blk(.two)],
                                          P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertFalse(f.isConsistentWithPlay(dominated),
            "P1 doubling the enemy pot with the Bull while holding a throwaway → reject")
    }

    // MARK: - (B) Bear decline

    /// P1, last to a FAT green trick ($40k) team 0 has won, plays a worthless
    /// yellow card while (per the world) holding the loose Bear. Declining a
    /// Bear that would have zeroed a fat enemy pot is dominated → reject.
    func testRejectsBearDeclineOnFatLostTrick() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.money40k)), (P(3), grn(.one)),
                        (P(0), grn(.two)),      (P(1), ylw(.one))],
                       trump: .red)
        XCTAssertEqual(tr.winner, P(2))
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let withBear = world(remaining: [P(0): [], P(1): [.bear],
                                         P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertFalse(f.isConsistentWithPlay(withBear),
            "holding the Bear and not zeroing a $40k enemy trick is dominated → reject")
    }

    /// Same shape but a WORTHLESS pot: declining the Bear is then sound (save
    /// it for a fat pot later), so the world must be kept.
    func testKeepsBearDeclineOnWorthlessTrick() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.one))],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let withBear = world(remaining: [P(0): [], P(1): [.bear],
                                         P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(withBear),
            "declining the Bear on a $0 trick is sound (save it) → keep")
    }

    /// Playing the Bear is never penalised — it is the GOOD play here.
    func testNeverFlagsPlayingTheBear() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.money40k)), (P(3), grn(.one)),
                        (P(0), grn(.two)),      (P(1), .bear)],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let w = world(remaining: [P(0): [], P(1): [ylw(.one)],
                                  P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(w),
            "the Bear cancelling a fat enemy pot is the correct play → keep")
    }

    // MARK: - No false positives: live contests are not judged

    /// P1 dumps the $10k while its PARTNER (P3) is already winning the trick —
    /// feeding partner, not the enemy. Even with a throwaway available the world
    /// must be kept (the certain-loss precondition is not met).
    func testKeepsMoneyFedToWinningPartner() {
        let me = P(0)
        // Leader P2; P3 (P1's partner) wins with the green $40k.
        let tr = trick(leader: P(2),
                       [(P(2), grn(.one)), (P(3), grn(.money40k)),
                        (P(0), grn(.two)), (P(1), ylw(.money10k))],
                       trump: .red)
        XCTAssertEqual(tr.winner, P(3))    // team 1 — P1's own team
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let w = world(remaining: [P(0): [], P(1): [blk(.two)],
                                  P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(w),
            "money fed to a winning partner is correct, never dominated → keep")
    }

    /// P1 could have RUFFED to win the trick (it holds a trump in this world)
    /// but played a money card instead. Because the trick was still winnable,
    /// the position is a live contest the filter must not judge.
    func testKeepsMoneyWhenSeatCouldStillWin() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.money10k))],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        // P1 also holds a red trump → could have overtaken to win the trick.
        let w = world(remaining: [P(0): [], P(1): [red(.three)],
                                  P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(w),
            "a trick the seat could still have won is a live contest → keep")
    }

    /// The ordinary, correct play — a worthless card to a lost trick — is
    /// always consistent.
    func testKeepsWorthlessCardToLostTrick() {
        let me = P(0)
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.one))],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: [], completed: [tr])
        let f = filter(v)
        let w = world(remaining: [P(0): [], P(1): [ylw(.two)],
                                  P(2): [], P(3): []], me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(w))
    }

    /// Pre-trick-play (no history) the filter is a no-op: nothing to verify.
    func testEmptyHistoryAlwaysConsistent() {
        let me = P(0)
        let v = view(me: me, trump: .red, myHand: [grn(.one)], completed: [])
        let f = filter(v)
        let w = world(remaining: [P(0): [grn(.one)], P(1): [grn(.two)],
                                  P(2): [grn(.three)], P(3): [grn(.four)]],
                      me: me, trump: .red)
        XCTAssertTrue(f.isConsistentWithPlay(w))
    }

    // MARK: - Wiring

    /// `sampleConsistent` never returns an inconsistent world when consistent
    /// ones are reachable, and never stalls. Built from the money-donation view:
    /// across many seeds it must only ever yield worlds the filter accepts.
    func testSampleConsistentOnlyReturnsConsistentWorlds() {
        let me = P(0)
        // A realistic mid-hand view: I (P0) hold a yellow suit; one completed
        // trick in which P1 dumped the $10k off-suit. Worlds that re-deal P1 a
        // cheap throwaway must never survive `sampleConsistent`.
        let myHand: [Card] = [ylw(.three), ylw(.four), ylw(.seven), ylw(.eight),
                              ylw(.nine), ylw(.eleven)]
        let tr = trick(leader: P(2),
                       [(P(2), grn(.eleven)), (P(3), grn(.one)),
                        (P(0), grn(.two)),    (P(1), ylw(.money10k))],
                       trump: .red)
        let v = view(me: me, trump: .red, myHand: myHand, completed: [tr])
        var produced = 0
        for s in 0..<40 {
            var det = Determinizer(view: v, seed: UInt64(s) &+ 1,
                                   filterDominatedDonation: true,
                                   filterBearDecline: true)
            guard let w = det.sampleConsistent() else { continue }
            produced += 1
            XCTAssertTrue(det.isConsistentWithPlay(w),
                "sampleConsistent returned an inconsistent world (seed \(s))")
        }
        XCTAssertGreaterThan(produced, 0, "sampleConsistent stalled on every seed")
    }

    /// Four agents with the filter on play a full hand to completion — wiring,
    /// performance, and no-stall sanity (mirrors the exact-endgame wiring test).
    func testAgentWithFilterSettlesAHand() async throws {
        var d = MonteCarloAgent.Difficulty.normal
        d.blunderRate = 0
        d.research.filterDominatedDonation = true
        d.research.filterBearDecline = true
        let agents: [PlayerAgent] = (0..<4).map {
            MonteCarloAgent(name: "PC\($0)", difficulty: d,
                            seed: UInt64($0) &* 7919 &+ 1)
        }
        let runner = GameRunner(agents: agents)
        let final = try await runner.playHand(dealer: P(0), dealSeed: 42)
        XCTAssertEqual(final.phase, .handComplete)
    }
}
