//
//  HandLogTests.swift
//  Make-a-MillionTests
//
//  The hand-log renderer is a pure function of a completed GameState. These
//  tests play a deterministic hand to completion and assert the trace carries
//  the full picture a reviewer needs: every section, all four seats, all 13
//  tricks, and the reconstructed declarer discard.
//

import XCTest
@testable import Make_A_Million_Mobile

final class HandLogTests: XCTestCase {

    private func playedHand(seed: UInt64, dealSeed: UInt64) async throws -> GameState {
        let agents = (0..<4).map { RandomAgent(name: "R\($0)", seed: seed &+ UInt64($0)) }
        let runner = GameRunner(agents: agents)
        // Disable misdeal so the deal is fixed and always reaches 13 tricks.
        return try await runner.playHand(dealer: PlayerID(0), dealSeed: dealSeed,
                                         misdealRule: .disabled)
    }

    func testRendersCompleteFullInfoTrace() async throws {
        let final = try await playedHand(seed: 100, dealSeed: 4242)
        XCTAssertEqual(final.phase, .handComplete)

        let labels = ["South (You)", "West", "North", "East"]
        let log = HandLog.render(final, handIndex: 0, seatLabels: labels)

        // Every section header is present.
        for header in ["HAND 1", "DEAL (full information)", "BIDDING",
                       "TRICKS", "RESULT", "HEURISTIC FLAGS"] {
            XCTAssertTrue(log.contains(header), "missing section: \(header)")
        }
        // All four seats appear in the deal block.
        for s in labels {
            XCTAssertTrue(log.contains(s), "deal should list \(s)")
        }
        // All 13 tricks are traced (one "wins" line each).
        let winLines = log.components(separatedBy: " wins").count - 1
        XCTAssertEqual(winLines, 13, "should trace exactly 13 tricks")
        // The declarer discard is reconstructed and labelled.
        XCTAssertTrue(log.contains("[reconstructed]"),
                      "declarer discard should be reconstructed")
    }

    func testFlagsSectionAlwaysPresent() async throws {
        // Different seed: whether or not a Bear-waste flag fires, the section
        // must always render (so a clean hand reads "none", not a gap).
        let final = try await playedHand(seed: 55, dealSeed: 77)
        let log = HandLog.render(final, handIndex: 4, seatLabels: ["S", "W", "N", "E"])
        XCTAssertTrue(log.contains("HAND 5"))            // handIndex is 0-based
        XCTAssertTrue(log.contains("HEURISTIC FLAGS"))
    }
}
