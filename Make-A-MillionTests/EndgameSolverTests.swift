//
//  EndgameSolverTests.swift
//  Make-a-MillionTests
//
//  Correctness locks for EndgameSolver (exact alpha-beta over determinized
//  endgames). Three layers:
//
//    1. EQUIVALENCE — the pruned, move-ordered solver must return exactly
//       the same value as a plain unpruned minimax on engine-generated
//       positions. This is the strong lock: alpha-beta and ordering are
//       speed optimisations and may never change a value.
//    2. A CRAFTED POSITION the greedy PlayoutPolicy provably misplays
//       (lead the boss trump to extract the ruffer BEFORE cashing the
//       side-suit money) where the exact values are computed by hand.
//       This is the documented reason the solver exists.
//    3. WIRING — a full hand played by agents with both exact-endgame
//       levers on settles cleanly.
//
//  Seating: team 0 = seats 0 & 2, team 1 = seats 1 & 3.
//

import XCTest
@testable import Make_A_Million_Mobile

final class EndgameSolverTests: XCTestCase {

    // MARK: - Helpers

    private func P(_ i: Int) -> PlayerID { PlayerID(i) }
    private func y(_ r: Card.Rank) -> Card { .colored(.yellow, r) }
    private func red(_ r: Card.Rank) -> Card { .colored(.red, r) }
    private func grn(_ r: Card.Rank) -> Card { .colored(.green, r) }

    /// Same builder as AITacticsTests: a mid-hand, full-information state
    /// via the memberwise initializer (what AIWorld.rebuild uses).
    private func trickState(hands: [PlayerID: [Card]],
                            trump: CardColor,
                            leader: PlayerID,
                            onTable: [(PlayerID, Card)],
                            toAct: PlayerID,
                            highBidder: PlayerID = PlayerID(1),
                            highBid: Int = 200_000) -> GameState {
        let plays = onTable.map { PlayedCard(player: $0.0, card: $0.1) }
        return GameState(
            dealSeed: 0,
            dealer: PlayerID(0),
            hands: hands,
            widow: [],
            phase: .trickPlay,
            toAct: toAct,
            highBid: highBid,
            highBidder: highBidder,
            passed: [],
            bidHistory: [],
            trump: trump,
            discardAnnouncement: nil,
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

    /// The leaf both implementations score with: final team-net difference.
    private func teamDiff(_ s: GameState, _ team: Int) -> Double {
        Double((s.matchScore[team] ?? 0) - (s.matchScore[1 - team] ?? 0))
    }

    /// Reference implementation: plain minimax, no pruning, no ordering,
    /// no budget. Slow and obviously correct — the solver must match it.
    private func bruteForce(_ state: GameState, myTeam: Int) -> Double? {
        if state.phase == .handComplete { return teamDiff(state, myTeam) }
        guard state.phase == .trickPlay else { return nil }
        let seat = state.toAct
        let maximizing = Seats.team(of: seat) == myTeam
        var best: Double? = nil
        for mv in state.legalMoves(for: seat) {
            guard let next = try? state.applying(mv, by: seat),
                  let v = bruteForce(next, myTeam: myTeam) else { continue }
            if let b = best {
                best = maximizing ? max(b, v) : min(b, v)
            } else {
                best = v
            }
        }
        return best
    }

    /// Drive a fresh seeded deal forward with seeded-random LEGAL moves
    /// until the side to act holds ≤ `cardsLeft` cards in trick play.
    /// Every move comes from the engine, so the position is reachable.
    private func randomEndgamePosition(seed: UInt64,
                                       cardsLeft: Int) -> GameState? {
        var s = GameState.newHand(dealer: PlayerID(0), seed: seed,
                                  misdealRule: .disabled)
        var rng = seed | 1
        func next(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(n))
        }
        var steps = 0
        while s.phase != .handComplete && steps < 800 {
            if s.phase == .trickPlay,
               (s.hands[s.toAct]?.count ?? 0) <= cardsLeft {
                return s
            }
            let moves = s.legalMoves(for: s.toAct)
            guard !moves.isEmpty,
                  let ns = try? s.applying(moves[next(moves.count)], by: s.toAct)
            else { return nil }
            s = ns
            steps += 1
        }
        return nil
    }

    // MARK: - 1. Equivalence with unpruned minimax

    func testSolverMatchesBruteForceOnSampledEndgames() {
        var checked = 0
        for seed: UInt64 in 1...30 {
            guard let pos = randomEndgamePosition(seed: seed, cardsLeft: 3)
            else { continue }
            // Alternate the perspective so min-at-root nodes are exercised
            // too, not just max-at-root.
            let myTeam = Int(seed % 2)
            guard let reference = bruteForce(pos, myTeam: myTeam) else { continue }
            let solved = EndgameSolver.solve(pos, myTeam: myTeam) {
                self.teamDiff($0, myTeam)
            }
            XCTAssertNotNil(solved, "seed \(seed): solver tripped its budget on a ≤3-trick position")
            XCTAssertEqual(solved ?? .nan, reference, accuracy: 0.5,
                           "seed \(seed): pruned value diverged from plain minimax")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 20,
            "random-walk generator produced too few testable positions")
    }

    // MARK: - 2. The crafted extraction position

    /// Two tricks left, seat 0 to lead, trump red, contract $200k at seat 1.
    ///   P0: [r11 (boss trump), grn$30k (boss green)]
    ///   P1: [r4 (last enemy trump), y1]      ← void in green: the ruffer
    ///   P2: [grn1, y2]    P3: [grn2, y4]
    ///
    /// Leading the green $30k first lets seat 1 ruff it with the r4
    /// (exact value +$200k for team 0 after the $200k set). Leading the
    /// boss trump FIRST extracts the r4, after which the $30k cashes
    /// cleanly (exact value +$230k). One trick of lookahead separates the
    /// lines — exactly what the greedy policy lacks and the solver has.
    private func extractionPosition() -> GameState {
        trickState(
            hands: [
                P(0): [red(.eleven), grn(.money30k)],
                P(1): [red(.four), y(.one)],
                P(2): [grn(.one), y(.two)],
                P(3): [grn(.two), y(.four)],
            ],
            trump: .red, leader: P(0), onTable: [], toAct: P(0))
    }

    func testSolverPrefersTrumpExtractionBeforeCashing() throws {
        let pos = extractionPosition()

        let afterTrumpLead = try pos.applying(.play(red(.eleven)), by: P(0))
        let afterMoneyLead = try pos.applying(.play(grn(.money30k)), by: P(0))

        let vTrump = EndgameSolver.solve(afterTrumpLead, myTeam: 0) {
            self.teamDiff($0, 0)
        }
        let vMoney = EndgameSolver.solve(afterMoneyLead, myTeam: 0) {
            self.teamDiff($0, 0)
        }

        // Hand-computed: extraction banks the $30k and sets the $200k
        // contract (+230k); cashing first donates the $30k to the ruff
        // (+200k after the set).
        XCTAssertEqual(vTrump ?? .nan, 230_000, accuracy: 0.5)
        XCTAssertEqual(vMoney ?? .nan, 200_000, accuracy: 0.5)
    }

    /// Documents the bias the solver removes: the greedy PlayoutPolicy
    /// leads the $30k into the ruff (its lead rules see "no sure winner,
    /// no low safe lead" and fall through to cheapest-by-strength). If
    /// this assertion ever FAILS, the policy learned the extraction —
    /// celebrate, then revisit whether the exact-endgame gates still pay.
    func testGreedyPolicyMissesTheExtractionLine() {
        let pos = extractionPosition()
        XCTAssertEqual(PlayoutPolicy.move(in: pos, seat: P(0)),
                       .play(grn(.money30k)))
    }

    // MARK: - 3. Budget valve + agent wiring

    func testBudgetExhaustionReturnsNil() {
        let pos = extractionPosition()
        let v = EndgameSolver.solve(pos, myTeam: 0, nodeBudget: 1) {
            self.teamDiff($0, 0)
        }
        XCTAssertNil(v, "a 1-node budget cannot complete a 2-trick solve")
    }

    func testAgentWithExactEndgameLeversSettlesAHand() async throws {
        var d = MonteCarloAgent.Difficulty.easy
        d.blunderRate = 0
        d.exactEndgameTricks = 4    // root decisions solved at ≤4 tricks
        d.rolloutExactTricks = 3    // rollout tails solved at ≤3 tricks
        let agents: [PlayerAgent] = (0..<4).map {
            MonteCarloAgent(name: "EX\($0)", difficulty: d,
                            seed: UInt64($0) &* 7919 &+ 1)
        }
        let runner = GameRunner(agents: agents)
        let final = try await runner.playHand(dealer: PlayerID(0), dealSeed: 42)
        XCTAssertEqual(final.phase, .handComplete)
    }
}
