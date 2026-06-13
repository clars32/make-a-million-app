//
//  AgentTests.swift
//  Make-a-Million
//
//  Verifies the agent layer and headless game loop: a full hand and a full
//  match play to completion with random agents, deterministically.
//

import XCTest
@testable import Make_A_Million_Mobile

final class AgentTests: XCTestCase {

    private func randomAgents(base: UInt64) -> [PlayerAgent] {
        (0..<4).map { RandomAgent(name: "R\($0)", seed: base &+ UInt64($0)) }
    }

    func testRandomAgentReturnsALegalMove() async throws {
        let g = GameState.newHand(dealer: PlayerID(0), seed: 1)
        let agent = RandomAgent(seed: 99)
        let view = g.view(for: g.view(for: PlayerID(0)).toAct)
        let move = await agent.chooseMove(from: view)
        XCTAssertTrue(view.legalMoves.contains(move),
                      "agent must only ever return a move from legalMoves")
    }

    func testFullHandPlaysToCompletion() async throws {
        let runner = GameRunner(agents: randomAgents(base: 1000))
        let final = try await runner.playHand(dealer: PlayerID(0), dealSeed: 555)

        XCTAssertEqual(final.phase, .handComplete)
        // 13 tricks captured between the two teams.
        let captured = (final.capturedByTeam[0]?.count ?? 0)
                     + (final.capturedByTeam[1]?.count ?? 0)
        XCTAssertEqual(captured, 13)
        // No Money lost: base captured Money across all tricks is exactly 400k.
        let allTricks = (final.capturedByTeam[0] ?? []) + (final.capturedByTeam[1] ?? [])
        let base = allTricks.flatMap { $0.plays }.reduce(0) { $0 + $1.card.moneyValue }
        XCTAssertEqual(base, 400_000)
    }

    func testHandIsDeterministicGivenSeeds() async throws {
        let r1 = GameRunner(agents: randomAgents(base: 7))
        let r2 = GameRunner(agents: randomAgents(base: 7))
        let a = try await r1.playHand(dealer: PlayerID(0), dealSeed: 42)
        let b = try await r2.playHand(dealer: PlayerID(0), dealSeed: 42)
        // Same seeds → same final scores and same trick count split.
        XCTAssertEqual(a.matchScore, b.matchScore)
        XCTAssertEqual(a.capturedByTeam[0]?.count, b.capturedByTeam[0]?.count)
    }

    func testMatchMachineryRunsAndAccumulates() async throws {
        // NOTE: random agents structurally CANNOT conclude a match. The
        // set-back rule drives a bidder who can't make its bid deeply
        // negative, so neither team converges toward +1,000,000 — verified:
        // ~ -$195M after 500 hands of random play. That is correct engine
        // behavior exposed by incompetent play, NOT a bug. So here we only
        // assert the match *machinery* is sound: many hands run, the dealer
        // rotates, score carries between hands. The "a match concludes with
        // a winner" assertion is deferred to the competent-agent milestone,
        // where it becomes meaningful.
        let runner = GameRunner(agents: randomAgents(base: 2024))

        var dealer = PlayerID(0)
        var carry: [Int: Int] = [0: 0, 1: 0]
        for hand in 0..<25 {
            let s = try await runner.playHand(
                dealer: dealer, dealSeed: 9000 &+ UInt64(hand), carryScore: carry)
            XCTAssertEqual(s.phase, .handComplete)
            carry = s.matchScore
            dealer = Seats.next(dealer)
        }
        // Score carried and moved across 25 hands (it won't be the initial 0/0).
        XCTAssertFalse(carry == [0: 0, 1: 0],
                       "scores must accumulate across hands")
    }

    func testPlayMatchTerminatesEvenWhenNoWinner() async throws {
        // playMatch must not hang under non-converging play — it should hit
        // its sanity ceiling and throw a clear error rather than loop forever.
        let runner = GameRunner(agents: randomAgents(base: 2024))
        do {
            _ = try await runner.playMatch(baseSeed: 9000)
            // If a competent-enough random seed *did* conclude, that's fine too.
        } catch RunnerError.matchDidNotConclude(let hands) {
            XCTAssertGreaterThan(hands, 0)   // terminated cleanly via the ceiling
        }
    }

    func testManyHandsNeverThrowOrStall() async throws {
        // Stress: 50 independent hands across varied seeds. Any state-machine
        // gap (deadlock, illegal-move-from-legalMoves) surfaces as a throw.
        for s in 0..<50 {
            let runner = GameRunner(agents: randomAgents(base: UInt64(s) &* 31 + 1))
            let final = try await runner.playHand(
                dealer: PlayerID(s % 4), dealSeed: UInt64(s) &* 2_654_435_761)
            XCTAssertEqual(final.phase, .handComplete)
        }
    }

    /// The agreement-mode misdeal vote must KEEP a strong hand (a redeal is
    /// triggered by ANY seat being money-poor, so we mustn't surrender a
    /// money-rich hand) and accept the fresh deal on a weak one. Automatic mode
    /// has only the forced redeal. Regression for the old `legal[0]` no-op that
    /// voted to redeal every time.
    func testMisdealKeepsStrongHandRedealsWeakOne() async {
        func view(_ myHand: [Card], _ legal: [Move]) -> PlayerView {
            PlayerView(me: PlayerID(0), myHand: myHand, phase: .misdealDecision,
                       toAct: PlayerID(0), trump: nil, highBid: nil,
                       highBidder: nil, passed: [], opener: PlayerID(0),
                       bidHistory: [], widow: nil, discardAnnouncement: nil,
                       currentTrick: nil, completedTrickCount: 0,
                       completedTricks: [], matchScore: [0: 0, 1: 0],
                       legalMoves: legal)
        }
        let agreement: [Move] = [.callMisdeal, .declineMisdeal]
        // Money-rich + long red trump — an obvious keep.
        let strong: [Card] = [.colored(.red, .money40k), .colored(.red, .money30k),
                              .colored(.red, .money15k), .colored(.red, .money10k),
                              .colored(.red, .money5k), .colored(.yellow, .money40k),
                              .colored(.yellow, .money30k), .colored(.yellow, .money15k),
                              .colored(.yellow, .money10k), .colored(.yellow, .money5k),
                              .colored(.red, .eleven), .colored(.red, .nine),
                              .colored(.red, .eight)]
        // Low, moneyless, no length — an obvious redeal.
        let weak: [Card] = [.colored(.red, .one), .colored(.red, .two),
                            .colored(.red, .three), .colored(.red, .four),
                            .colored(.yellow, .one), .colored(.yellow, .two),
                            .colored(.yellow, .three), .colored(.green, .one),
                            .colored(.green, .two), .colored(.green, .three),
                            .colored(.black, .one), .colored(.black, .two),
                            .colored(.black, .three)]
        let agent = MonteCarloAgent(difficulty: .normal, seed: 1)
        let keep = await agent.chooseMove(from: view(strong, agreement))
        XCTAssertEqual(keep, .declineMisdeal,
                       "a money-rich hand must not be surrendered to a redeal")
        let redeal = await agent.chooseMove(from: view(weak, agreement))
        XCTAssertEqual(redeal, .callMisdeal, "a weak hand should take the fresh deal")
        let forced = await agent.chooseMove(from: view(weak, [.callMisdeal]))
        XCTAssertEqual(forced, .callMisdeal, "automatic mode has only the redeal")
    }
}
