//
//  ResumeTests.swift
//  Make-a-Million
//
//  The resume feature rests on one invariant: the recorded move log replays,
//  through the same reducer, to the exact state it was recorded from. These
//  tests pin that down — a faithful log, a full-log resume that matches the
//  original outcome, a mid-hand prefix that reconstructs and then continues to
//  a legal completion, and the forced auto-misdeal redeal being recorded and
//  replayed like any other move.
//

import XCTest
@testable import Make_A_Million_Mobile

final class ResumeTests: XCTestCase {

    /// Accumulates the runner's `onMove` emissions across actor hops.
    private actor MoveCollector {
        private(set) var moves: [RecordedMove] = []
        func add(_ m: RecordedMove) { moves.append(m) }
    }

    private func randomAgents(base: UInt64) -> [PlayerAgent] {
        (0..<4).map { RandomAgent(name: "R\($0)", seed: base &+ UInt64($0)) }
    }

    /// Replay a log from a fresh deal, the same way `resumeHand` does internally.
    private func reconstruct(seed: UInt64,
                             dealer: PlayerID,
                             carry: [Int: Int],
                             misdealRule: MisdealRule,
                             moves: [RecordedMove]) throws -> GameState {
        var s = GameState.newHand(dealer: dealer, seed: seed,
                                  carryScore: carry, misdealRule: misdealRule)
        for m in moves { s = try s.applying(m.move, by: m.player) }
        return s
    }

    /// Compare the observable outcome of two states without needing Equatable.
    private func assertSameOutcome(_ a: GameState, _ b: GameState,
                                   _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.phase, b.phase, "phase \(message)", file: file, line: line)
        XCTAssertEqual(a.matchScore, b.matchScore, "matchScore \(message)", file: file, line: line)
        XCTAssertEqual(a.completedTricks.count, b.completedTricks.count,
                       "tricks \(message)", file: file, line: line)
        XCTAssertEqual(a.capturedByTeam[0]?.count, b.capturedByTeam[0]?.count,
                       "team0 \(message)", file: file, line: line)
        XCTAssertEqual(a.capturedByTeam[1]?.count, b.capturedByTeam[1]?.count,
                       "team1 \(message)", file: file, line: line)
    }

    // MARK: - Faithful log

    /// The move log captured during a hand replays to the same final state.
    func testMoveLogReconstructsHand() async throws {
        for s in 0..<20 {
            let seed = UInt64(s) &* 2_654_435_761 &+ 1
            let dealer = PlayerID(s % 4)
            let collector = MoveCollector()
            let runner = GameRunner(agents: randomAgents(base: UInt64(s) &* 31 + 7))

            let final = try await runner.playHand(
                dealer: dealer, dealSeed: seed,
                onMove: { m in await collector.add(m) })

            let moves = await collector.moves
            let rebuilt = try reconstruct(seed: seed, dealer: dealer,
                                          carry: [0: 0, 1: 0],
                                          misdealRule: .standard, moves: moves)
            XCTAssertEqual(rebuilt.phase, .handComplete)
            assertSameOutcome(rebuilt, final, "seed \(seed)")
        }
    }

    // MARK: - Full-log resume

    /// Resuming with the complete log re-deals, replays every move (the hand is
    /// already over after replay), and returns the original outcome unchanged.
    func testResumeFullLogMatchesOriginal() async throws {
        let seed: UInt64 = 4242
        let dealer = PlayerID(1)
        let collector = MoveCollector()
        let runner = GameRunner(agents: randomAgents(base: 1234))

        let original = try await runner.playHand(
            dealer: dealer, dealSeed: seed,
            onMove: { m in await collector.add(m) })
        let log = await collector.moves

        let resumed = try await runner.resumeHand(
            dealer: dealer, dealSeed: seed, carryScore: [0: 0, 1: 0],
            misdealRule: .standard, endgameRule: .standard, houseRules: .standard,
            moves: log)

        assertSameOutcome(resumed, original, "full-log resume")
    }

    // MARK: - Mid-hand prefix

    /// A prefix of the log reconstructs the exact mid-hand position, and the
    /// runner continues it (with live agents) to a legal, complete hand.
    func testResumePrefixReconstructsThenCompletes() async throws {
        let seed: UInt64 = 777
        let dealer = PlayerID(0)
        let collector = MoveCollector()
        let logRunner = GameRunner(agents: randomAgents(base: 99))

        _ = try await logRunner.playHand(
            dealer: dealer, dealSeed: seed,
            onMove: { m in await collector.add(m) })
        let fullLog = await collector.moves
        XCTAssertGreaterThan(fullLog.count, 6, "need a non-trivial hand to slice")

        // Take a prefix that lands somewhere in trick play.
        let prefix = Array(fullLog.prefix(fullLog.count - 5))

        // The reducer reconstruction of the prefix is a valid, in-progress hand.
        let midState = try reconstruct(seed: seed, dealer: dealer,
                                       carry: [0: 0, 1: 0],
                                       misdealRule: .standard, moves: prefix)
        XCTAssertNotEqual(midState.phase, .handComplete,
                          "prefix should be mid-hand, not finished")

        // Resuming from that prefix with fresh agents finishes a legal hand.
        let resumeRunner = GameRunner(agents: randomAgents(base: 55))
        let final = try await resumeRunner.resumeHand(
            dealer: dealer, dealSeed: seed, carryScore: [0: 0, 1: 0],
            misdealRule: .standard, endgameRule: .standard, houseRules: .standard,
            moves: prefix)

        XCTAssertEqual(final.phase, .handComplete)
        let captured = (final.capturedByTeam[0]?.count ?? 0)
                     + (final.capturedByTeam[1]?.count ?? 0)
        XCTAssertEqual(captured, 13, "a completed hand has all 13 tricks")
    }

    // MARK: - Auto-misdeal recording

    /// The forced auto-misdeal redeal is recorded as a move and replays. We
    /// deterministically find a seed whose deal starts short (so the runner
    /// applies `.callMisdeal` itself), then verify the log carries it and
    /// reconstructs.
    func testResumeReplaysAutoMisdeal() async throws {
        // A high threshold makes short deals common; scan for one to stay
        // deterministic rather than flaky.
        let rule = MisdealRule(enabled: true, threshold: 45_000)
        var seed: UInt64 = 1
        while GameState.newHand(dealer: PlayerID(0), seed: seed,
                                misdealRule: rule).phase != .misdealDecision {
            seed += 1
            precondition(seed < 5000, "expected a short deal within range")
        }

        let collector = MoveCollector()
        let runner = GameRunner(agents: randomAgents(base: 17))
        let final = try await runner.playHand(
            dealer: PlayerID(0), dealSeed: seed, misdealRule: rule,
            onMove: { m in await collector.add(m) })
        let log = await collector.moves

        XCTAssertTrue(log.contains { $0.move == .callMisdeal },
                      "an auto-misdeal redeal must be recorded in the log")

        let rebuilt = try reconstruct(seed: seed, dealer: PlayerID(0),
                                      carry: [0: 0, 1: 0],
                                      misdealRule: rule, moves: log)
        assertSameOutcome(rebuilt, final, "auto-misdeal seed \(seed)")
    }
}
