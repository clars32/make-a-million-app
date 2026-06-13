//
//  ISMCTSTests.swift
//  Make-a-MillionTests
//
//  Correctness/convergence locks for single-observer IS-MCTS (`AI/ISMCTS.swift`).
//  IS-MCTS is stochastic, so the locks are convergence properties, not exact
//  values:
//
//    1. CONVERGENCE — on the full-information 2-trick extraction position (the
//       same case that motivates EndgameSolver), determinization is trivial
//       (one world), so a sound search must find the lookahead the greedy
//       PlayoutPolicy misses: lead the boss trump to pull the ruffer BEFORE
//       cashing the side money. IS-MCTS must prefer that lead.
//    2. DETERMINISM — fed the same seeded RNG stream and world, the search
//       produces identical per-move visit counts (reproducible decisions, like
//       the rest of the AI).
//    3. WIRING — four agents with `useISMCTS` on play a full hand to completion.
//
//  Seating: team 0 = seats 0 & 2, team 1 = seats 1 & 3.
//

import XCTest
@testable import Make_A_Million_Mobile

final class ISMCTSTests: XCTestCase {

    // MARK: - Helpers

    private func P(_ i: Int) -> PlayerID { PlayerID(i) }
    private func y(_ r: Card.Rank) -> Card { .colored(.yellow, r) }
    private func red(_ r: Card.Rank) -> Card { .colored(.red, r) }
    private func grn(_ r: Card.Rank) -> Card { .colored(.green, r) }

    private func teamDiff(_ s: GameState, _ team: Int) -> Double {
        Double((s.matchScore[team] ?? 0) - (s.matchScore[1 - team] ?? 0))
    }

    /// Roll a state out to terminal with the greedy policy, then score it —
    /// the leaf evaluator IS-MCTS uses (terminal states score immediately).
    private func rollout(_ s: GameState, team: Int) -> Double {
        var st = s
        var steps = 0
        while st.phase != .handComplete && steps < 200 {
            let mv = PlayoutPolicy.move(in: st, seat: st.toAct)
            guard let ns = try? st.applying(mv, by: st.toAct) else { break }
            st = ns
            steps += 1
        }
        return teamDiff(st, team)
    }

    /// Deterministic RNG stream for reproducible searches.
    private func rngStream(seed: UInt64) -> () -> UInt64 {
        var s = seed | 1
        return {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return s
        }
    }

    /// The EndgameSolver motivating position: two tricks left, seat 0 to lead,
    /// trump red, contract $200k at seat 1.
    ///   P0: [r11 (boss trump), grn$30k]   P1: [r4 (last enemy trump), y1]
    ///   P2: [grn1, y2]                     P3: [grn2, y4]
    private func extractionPosition() -> GameState {
        GameState(
            dealSeed: 0, dealer: P(0),
            hands: [P(0): [red(.eleven), grn(.money30k)],
                    P(1): [red(.four), y(.one)],
                    P(2): [grn(.one), y(.two)],
                    P(3): [grn(.two), y(.four)]],
            widow: [], phase: .trickPlay, toAct: P(0),
            highBid: 200_000, highBidder: P(1), passed: [], bidHistory: [],
            trump: .red, discardAnnouncement: nil,
            misdealRule: .disabled, endgameRule: .standard,
            currentTrick: Trick(leader: P(0)), completedTricks: [],
            capturedByTeam: [0: [], 1: []], matchScore: [0: 0, 1: 0],
            dealtHands: [:], dealtWidow: [])
    }

    private func search(_ state: GameState, rootCandidates: [Move],
                        rootTeam: Int, iterations: Int,
                        seed: UInt64) -> [ISMCTS.RootStat] {
        let next = rngStream(seed: seed)
        return ISMCTS.search(
            rootCandidates: rootCandidates,
            rootTeam: rootTeam,
            iterations: iterations,
            sampleWorld: { state },                 // full info → one world
            leafValue: { self.rollout($0, team: rootTeam) },
            policyMove: { PlayoutPolicy.move(in: $0, seat: $0.toAct) },
            nextRandom: next)
    }

    // MARK: - 1. Convergence on the extraction position

    func testFindsTrumpExtractionLineOnFullInfoEndgame() {
        let pos = extractionPosition()
        let cands: [Move] = [.play(red(.eleven)), .play(grn(.money30k))]
        let stats = search(pos, rootCandidates: cands, rootTeam: 0,
                           iterations: 4000, seed: 12345)

        // Robust child: the most-visited root move.
        let chosen = stats.max { $0.visits < $1.visits }
        XCTAssertEqual(chosen?.move, .play(red(.eleven)),
            "IS-MCTS should pull the ruffer's trump first (the line greedy misses)")

        // And the extraction line should value ABOVE the cash-first line.
        func mean(_ m: Move) -> Double {
            guard let s = stats.first(where: { $0.move == m }), s.visits > 0
            else { return -.infinity }
            return s.total / Double(s.visits)
        }
        XCTAssertGreaterThan(mean(.play(red(.eleven))), mean(.play(grn(.money30k))),
            "extraction lead must value higher than cashing into the ruff")
    }

    /// Sanity: the greedy policy genuinely leads the losing (cash-first) line,
    /// so the search above isn't just echoing the rollout policy. (Mirror of
    /// EndgameSolverTests' guard — if this flips, the policy learned the line.)
    func testGreedyPolicyStillMissesIt() {
        XCTAssertEqual(PlayoutPolicy.move(in: extractionPosition(), seat: P(0)),
                       .play(grn(.money30k)))
    }

    // MARK: - 2. Determinism

    func testDeterministicGivenSameSeed() {
        let pos = extractionPosition()
        let cands: [Move] = [.play(red(.eleven)), .play(grn(.money30k))]
        let a = search(pos, rootCandidates: cands, rootTeam: 0,
                       iterations: 600, seed: 99)
        let b = search(pos, rootCandidates: cands, rootTeam: 0,
                       iterations: 600, seed: 99)
        let va = Dictionary(uniqueKeysWithValues: a.map { ($0.move, $0.visits) })
        let vb = Dictionary(uniqueKeysWithValues: b.map { ($0.move, $0.visits) })
        XCTAssertEqual(va, vb, "same seed + world must give identical visit counts")
    }

    /// Every returned root stat is one of the candidates and they sum to the
    /// iteration budget (each iteration backs up exactly one root child).
    func testVisitsCoverCandidatesAndSumToBudget() {
        let pos = extractionPosition()
        let cands: [Move] = [.play(red(.eleven)), .play(grn(.money30k))]
        let stats = search(pos, rootCandidates: cands, rootTeam: 0,
                           iterations: 500, seed: 7)
        for s in stats { XCTAssertTrue(cands.contains(s.move)) }
        XCTAssertEqual(stats.reduce(0) { $0 + $1.visits }, 500,
            "root visits should total the iteration budget")
    }

    // MARK: - 3. Wiring

    func testAgentWithISMCTSSettlesAHand() async throws {
        var d = MonteCarloAgent.Difficulty.normal
        d.blunderRate = 0
        d.useISMCTS = true
        let agents: [PlayerAgent] = (0..<4).map {
            MonteCarloAgent(name: "IS\($0)", difficulty: d,
                            seed: UInt64($0) &* 7919 &+ 1)
        }
        let runner = GameRunner(agents: agents)
        let final = try await runner.playHand(dealer: P(0), dealSeed: 42)
        XCTAssertEqual(final.phase, .handComplete)
    }
}
