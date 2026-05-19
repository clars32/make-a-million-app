//
//  AIArena.swift
//  Make-a-Million
//
//  The yardstick. The Monte Carlo agent is NOT verified by assertions — it
//  is verified by decisively beating RandomAgent over many seeded matches,
//  and later by you watching it play in the app (that is what the visibility
//  pass was for). If it cannot crush random, it is broken; if it barely wins,
//  it needs tuning. This harness gives you that number on demand.
//
//  Headless. No SwiftUI. Reuses GameRunner unchanged — the AI is just an
//  agent, exactly like the human and the random bot.
//
//  Call it from a unit test or a throwaway button:
//
//      let r = await AIArena.run(matches: 40,
//                                difficulty: .medium,
//                                baseSeed: 1)
//      print(r.summary)
//
//  ENGINE BINDING: GameRunner(agents:) / .playMatch ; PlayerID ; Seats ;
//  RandomAgent ; MonteCarloAgent.
//

import Foundation

enum AIArena {

    struct Result {
        let matches: Int
        let mcWins: Int            // matches won by the MC partnership
        let randomWins: Int
        let mcAvgFinalScore: Double
        let randomAvgFinalScore: Double
        let failures: Int          // matches that errored / didn't conclude

        var mcWinRate: Double {
            let played = matches - failures
            return played > 0 ? Double(mcWins) / Double(played) : 0
        }

        var summary: String {
            """
            AIArena — \(matches) matches (\(failures) failed)
              MC partnership won      : \(mcWins)  (\(pct(mcWinRate)))
              Random partnership won  : \(randomWins)
              MC avg final score      : \(money(mcAvgFinalScore))
              Random avg final score  : \(money(randomAvgFinalScore))
            VERDICT: \(verdict)
            """
        }

        private var verdict: String {
            switch mcWinRate {
            case 0.85...:     return "crushing — wired correctly, now tune for fun"
            case 0.65..<0.85: return "winning but soft — playout/bidding need work"
            case 0.45..<0.65: return "coin-flip — something is wrong, not just untuned"
            default:          return "LOSING to random — a real bug; check bindings"
            }
        }
        private func pct(_ d: Double) -> String {
            String(format: "%.0f%%", d * 100)
        }
        private func money(_ d: Double) -> String {
            String(format: "$%.0fk", d / 1000)
        }
    }

    /// Run `matches` full matches. The MC partnership sits seats 0 & 2; the
    /// random partnership sits 1 & 3. Seats are swapped every other match so
    /// neither side gets a permanent dealer/opening-bid advantage.
    static func run(matches: Int,
                    difficulty: MonteCarloAgent.Difficulty = .medium,
                    baseSeed: UInt64 = 1) async -> Result {

        var mcWins = 0, randomWins = 0, failures = 0
        var mcScoreSum = 0.0, randomScoreSum = 0.0

        for m in 0..<matches {
            let seed = baseSeed &+ UInt64(m) &* 1_000_003
            let swap = (m % 2 == 1)

            // Team 0 = seats 0,2 ; Team 1 = seats 1,3 (engine convention).
            let mcTeam = swap ? 1 : 0
            let mc0 = MonteCarloAgent(name: "MC-A", difficulty: difficulty,
                                      seed: seed &+ 11)
            let mc1 = MonteCarloAgent(name: "MC-B", difficulty: difficulty,
                                      seed: seed &+ 22)
            let rnd0 = RandomAgent(name: "Rnd-A", seed: seed &+ 33)
            let rnd1 = RandomAgent(name: "Rnd-B", seed: seed &+ 44)

            let agents: [PlayerAgent] = swap
                ? [rnd0, mc0, rnd1, mc1]      // MC on the odd seats
                : [mc0, rnd0, mc1, rnd1]      // MC on the even seats

            let runner = GameRunner(agents: agents)
            do {
                let (winner, final) = try await runner.playMatch(baseSeed: seed)
                let mcFinal     = Double(final.matchScore[mcTeam] ?? 0)
                let randomFinal = Double(final.matchScore[1 - mcTeam] ?? 0)
                mcScoreSum     += mcFinal
                randomScoreSum += randomFinal
                if winner == mcTeam { mcWins += 1 } else { randomWins += 1 }
            } catch {
                failures += 1
            }
        }

        let played = max(1, matches - failures)
        return Result(
            matches: matches,
            mcWins: mcWins,
            randomWins: randomWins,
            mcAvgFinalScore: mcScoreSum / Double(played),
            randomAvgFinalScore: randomScoreSum / Double(played),
            failures: failures)
    }

    /// Quick single-hand trace for eyeballing *what* the AI does (the
    /// instrument-panel companion to the win-rate number). Prints each AI
    /// decision's phase and chosen move.
    static func traceOneHand(difficulty: MonteCarloAgent.Difficulty = .medium,
                             dealSeed: UInt64 = 1) async {
        let agents: [PlayerAgent] = [
            MonteCarloAgent(name: "MC-South", difficulty: difficulty, seed: 1),
            RandomAgent(name: "West",  seed: 2),
            MonteCarloAgent(name: "MC-North", difficulty: difficulty, seed: 3),
            RandomAgent(name: "East",  seed: 4),
        ]
        let runner = GameRunner(agents: agents)
        do {
            let final = try await runner.playHand(dealer: PlayerID(0),
                                                  dealSeed: dealSeed)
            print("Trace done. Hand settled. matchScore = \(final.matchScore)")
        } catch {
            print("Trace failed: \(error)")
        }
    }
}
