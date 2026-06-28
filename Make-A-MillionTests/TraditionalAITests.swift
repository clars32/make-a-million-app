//
//  TraditionalAITests.swift
//  Make-a-MillionTests
//
//  Validation for the Traditional (legible, capability-laddered) AI stack.
//  The yardstick here is NOT "beats the old champion" — it is legibility,
//  reproducibility, and the principled key (ai_rewrite.md §7). The slow
//  monotonicity self-play (novice < casual < skilled < expert) lives in
//  AIArenaTests so the quick suite stays fast.
//

import XCTest
@testable import Make_A_Million_Mobile

final class TraditionalAITests: XCTestCase {

    private func ladderAgents(_ level: MonteCarloAgent.Difficulty,
                              base: UInt64) -> [MonteCarloAgent] {
        (0..<4).map { MonteCarloAgent(name: "T\($0)", difficulty: level,
                                      seed: base &+ UInt64($0) &* 7) }
    }

    private let tiers: [(String, MonteCarloAgent.Difficulty)] = [
        ("novice", .novice), ("casual", .casual),
        ("skilled", .skilled), ("expert", .expert)
    ]

    // MARK: - Smoke: every tier plays full hands cleanly

    func testTraditionalTiersPlayFullHandsToCompletion() async throws {
        for (name, profile) in tiers {
            let runner = GameRunner(agents: ladderAgents(profile, base: 1))
            for h in 0..<3 {
                let final = try await runner.playHand(dealer: PlayerID(h % 4),
                                                      dealSeed: 100 &+ UInt64(h))
                XCTAssertEqual(final.phase, .handComplete, "\(name) hand \(h)")
                let captured = (final.capturedByTeam[0]?.count ?? 0)
                             + (final.capturedByTeam[1]?.count ?? 0)
                XCTAssertEqual(captured, 13, "\(name) hand \(h): 13 tricks")
                let allTricks = (final.capturedByTeam[0] ?? []) + (final.capturedByTeam[1] ?? [])
                let base = allTricks.flatMap { $0.plays }.reduce(0) { $0 + $1.card.moneyValue }
                XCTAssertEqual(base, 400_000, "\(name) hand \(h): money conserved")
            }
        }
    }

    // MARK: - Legibility (the hard gate, §7.1)

    /// Step real hands and assert EVERY non-forced trick-play move a Traditional
    /// agent makes is a member of its deterministic principled candidate set —
    /// i.e. it never plays a card no principle put forward.
    func testEveryTraditionalTrickMoveIsPrincipled() async throws {
        for (name, profile) in tiers {
            let agents = ladderAgents(profile, base: 42)
            for seed in [7, 31, 88, 204] {
                var s = GameState.newHand(dealer: PlayerID(0), seed: UInt64(seed))
                var guardSteps = 0
                while s.phase != .handComplete && guardSteps < 400 {
                    guardSteps += 1
                    let seat = s.toAct
                    let view = s.view(for: seat)
                    let agent = agents[seat.raw]
                    let move = await agent.chooseMove(from: view)
                    XCTAssertTrue(view.legalMoves.contains(move),
                                  "\(name): agent returned an illegal move")
                    if s.phase == .trickPlay && view.legalMoves.count > 1 {
                        let inf = TableInference(
                            view: view, inference: profile.capabilities.inference)
                        let cands = agent.traditionalCandidates(
                            view: view, legal: view.legalMoves, inference: inf)
                        XCTAssertFalse(cands.isEmpty,
                                       "\(name): principled candidate set is empty")
                        XCTAssertTrue(cands.contains { .play($0.card) == move },
                                      "\(name) seed \(seed): played \(move) "
                                      + "outside the principled set")
                    }
                    s = try s.applying(move, by: seat)
                }
                XCTAssertEqual(s.phase, .handComplete, "\(name) seed \(seed) finished")
            }
        }
    }

    // MARK: - Reproducibility (§7.4)

    /// The same (seed, position) yields the same Traditional play — randomization
    /// draws from the agent's seedBox, so two identically-seeded runs match.
    func testTraditionalPlayIsReproducible() async throws {
        for (name, profile) in tiers {
            let a = GameRunner(agents: ladderAgents(profile, base: 5))
            let b = GameRunner(agents: ladderAgents(profile, base: 5))
            let r1 = try await a.playHand(dealer: PlayerID(0), dealSeed: 909)
            let r2 = try await b.playHand(dealer: PlayerID(0), dealSeed: 909)
            XCTAssertEqual(r1.matchScore, r2.matchScore, "\(name): score reproducible")
            XCTAssertEqual(r1.capturedByTeam[0]?.count,
                           r2.capturedByTeam[0]?.count, "\(name): split reproducible")
        }
    }

    // MARK: - The principled key (§2.3, §8)

    private func ctx(bank: Bool,
                     myTops: [CardColor: Card] = [:]) -> MonteCarloAgent.KeyContext {
        MonteCarloAgent.KeyContext(trump: .red, bankToOwnTeam: bank, myTops: myTops)
    }
    private let agent = MonteCarloAgent(difficulty: .skilled, seed: 1)
    private func y(_ r: Card.Rank) -> Card { .colored(.yellow, r) }
    private func grn(_ r: Card.Rank) -> Card { .colored(.green, r) }

    /// Banking onto our own team takes the MOST money (handlog "Y$30 over Y$40"
    /// was the bug; the key prefers the higher money when banking).
    func testKeyBanksTheMostMoneyOntoOwnTeam() {
        XCTAssertTrue(agent.principledKey(y(.money40k), ctx: ctx(bank: true))
                    < agent.principledKey(y(.money30k), ctx: ctx(bank: true)))
    }

    /// Feeding an opponent's trick (or leading) commits the LEAST money
    /// ("G$40 over G$5" was the bug).
    func testKeyStarvesOpponentBoundTricks() {
        XCTAssertTrue(agent.principledKey(grn(.money5k), ctx: ctx(bank: false))
                    < agent.principledKey(grn(.money40k), ctx: ctx(bank: false)))
    }

    /// Specials are never spent on a tie, Tiger worst of all.
    func testKeyNeverSpendsSpecialsOnATie() {
        XCTAssertTrue(agent.principledKey(grn(.one), ctx: ctx(bank: false))
                    < agent.principledKey(.bear, ctx: ctx(bank: false)))
        XCTAssertTrue(agent.principledKey(.bear, ctx: ctx(bank: false))
                    < agent.principledKey(.tiger, ctx: ctx(bank: false)))
    }

    /// Among otherwise-equal cards, a future controller (my top of its color)
    /// is NOT burned on a tie — the non-controller sorts first.
    func testKeyPreservesControllersOnATie() {
        let myTops: [CardColor: Card] = [.green: grn(.nine)]
        XCTAssertTrue(agent.principledKey(grn(.eight), ctx: ctx(bank: false, myTops: myTops))
                    < agent.principledKey(grn(.nine), ctx: ctx(bank: false, myTops: myTops)),
                      "the controller (green 9) must sort after the junk green 8")
    }
}
