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
//                                difficulty: .normal,
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
                    difficulty: MonteCarloAgent.Difficulty = .normal,
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

    // MARK: - Self-play A/B harness + bidding telemetry

    /// Result of a "challenger vs champion" self-play run. Unlike the vs-Random
    /// arena, both sides are competent, so this measures whether a *change*
    /// actually wins more — and surfaces the bidding telemetry that the
    /// vs-Random run cannot (random opponents never punish under-bidding).
    struct SelfPlayResult {
        let matches: Int
        let challengerWins: Int     // the partnership under test ("new")
        let championWins: Int       // the baseline ("old")
        let failures: Int

        // Per-hand telemetry, aggregated across every hand of every match.
        let hands: Int
        let declaredByChallenger: Int   // hands the challenger team won the bid
        let declaredByChampion: Int
        let setsByChallenger: Int       // contracts the challenger went set on
        let setsByChampion: Int
        let contractSumChallenger: Int  // Σ winning bid when challenger declared
        let contractSumChampion: Int

        var challengerWinRate: Double {
            let played = matches - failures
            return played > 0 ? Double(challengerWins) / Double(played) : 0
        }
        private func avg(_ sum: Int, _ n: Int) -> Double { n > 0 ? Double(sum) / Double(n) : 0 }
        private func rate(_ a: Int, _ b: Int) -> Double { (a + b) > 0 ? Double(a) / Double(a + b) : 0 }

        var summary: String {
            """
            AIArena self-play — \(matches) matches (\(failures) failed), \(hands) hands
              Challenger won matches : \(challengerWins)  (\(pct(challengerWinRate)))
              Champion   won matches : \(championWins)
              Bid share (challenger) : \(pct(rate(declaredByChallenger, declaredByChampion)))
              Avg contract (chal/champ): \(money(avg(contractSumChallenger, declaredByChallenger))) / \(money(avg(contractSumChampion, declaredByChampion)))
              Set-rate (chal/champ)  : \(pct(avg(setsByChallenger, declaredByChallenger))) / \(pct(avg(setsByChampion, declaredByChampion)))
            VERDICT: \(verdict)
            """
        }
        private var verdict: String {
            switch challengerWinRate {
            case 0.58...:    return "challenger clearly stronger — keep the change"
            case 0.52..<0.58: return "challenger edge — promising, widen the run to confirm"
            case 0.48..<0.52: return "no measurable difference"
            default:          return "challenger WEAKER — revert or rethink the change"
            }
        }
        private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
        private func money(_ d: Double) -> String { String(format: "$%.0fk", d / 1000) }
    }

    /// Run `matches` of challenger (seats rotate) vs champion. Both are
    /// MonteCarloAgents; pass two `Difficulty` profiles to A/B a tuning change
    /// (e.g. a more aggressive bid profile against the current one). Seats swap
    /// every other match so neither side gets a permanent opening-bid edge.
    static func runSelfPlay(matches: Int,
                            challenger: MonteCarloAgent.Difficulty,
                            champion: MonteCarloAgent.Difficulty,
                            baseSeed: UInt64 = 1) async -> SelfPlayResult {
        var chalWins = 0, champWins = 0, failures = 0
        var hands = 0
        var declChal = 0, declChamp = 0
        var setsChal = 0, setsChamp = 0
        var contractChal = 0, contractChamp = 0

        for m in 0..<matches {
            let seed = baseSeed &+ UInt64(m) &* 1_000_003
            let swap = (m % 2 == 1)
            let chalTeam = swap ? 1 : 0

            let c0 = MonteCarloAgent(name: "Chal-A", difficulty: challenger, seed: seed &+ 11)
            let c1 = MonteCarloAgent(name: "Chal-B", difficulty: challenger, seed: seed &+ 22)
            let p0 = MonteCarloAgent(name: "Champ-A", difficulty: champion, seed: seed &+ 33)
            let p1 = MonteCarloAgent(name: "Champ-B", difficulty: champion, seed: seed &+ 44)
            let agents: [PlayerAgent] = swap ? [p0, c0, p1, c1] : [c0, p0, c1, p1]
            let runner = GameRunner(agents: agents)

            // Play the match hand-by-hand so we can read each hand's contract
            // outcome via debugReveal(). Mirrors GameRunner.playMatch's loop.
            var dealer = PlayerID(0)
            var carry: [Int: Int] = [0: 0, 1: 0]
            var handIndex: UInt64 = 0
            let maxHands: UInt64 = 500
            var concluded = false
            do {
                while handIndex < maxHands {
                    let final = try await runner.playHand(
                        dealer: dealer, dealSeed: seed &+ handIndex, carryScore: carry)
                    hands += 1
                    if let rv = final.debugReveal(), let declarer = rv.declarer,
                       let contract = rv.contract {
                        let declIsChal = (Seats.team(of: declarer) == chalTeam)
                        if declIsChal {
                            declChal += 1; contractChal += contract; if !rv.made { setsChal += 1 }
                        } else {
                            declChamp += 1; contractChamp += contract; if !rv.made { setsChamp += 1 }
                        }
                    }
                    if let winner = final.matchWinner {
                        if winner == chalTeam { chalWins += 1 } else { champWins += 1 }
                        concluded = true
                        break
                    }
                    carry = final.matchScore
                    dealer = Seats.next(dealer)
                    handIndex &+= 1
                }
                if !concluded { failures += 1 }
            } catch {
                failures += 1
            }
        }

        return SelfPlayResult(
            matches: matches, challengerWins: chalWins, championWins: champWins,
            failures: failures, hands: hands,
            declaredByChallenger: declChal, declaredByChampion: declChamp,
            setsByChallenger: setsChal, setsByChampion: setsChamp,
            contractSumChallenger: contractChal, contractSumChampion: contractChamp)
    }

    // MARK: - Bid calibration (is the evaluator too conservative?)
    //
    // Self-play CANNOT answer "is the AI too conservative" — two timid players
    // reach a quiet equilibrium where neither punishes the other's caution.
    // This instrument needs no opponent: it counterfactually forces each seat
    // to DECLARE at the opening floor and plays the hand out under competent
    // play, then compares the evaluator's `expectedGross` to the gross the
    // team actually captured. If hands the evaluator scores BELOW the floor
    // routinely capture at or above it, the evaluator under-values — i.e. the
    // AI is passing makeable hands, which is conservatism in an absolute sense.

    struct CalibrationResult {
        let hands: Int                 // counterfactual declarer playouts
        let avgEstimate: Double
        let avgRealized: Double
        /// realized − estimate. Positive ⇒ the evaluator UNDER-values (bids
        /// too little); negative ⇒ it over-values (bids into sets).
        let realizedMinusEstimate: Double
        let madeFloor: Int             // captured ≥ opening minimum
        // Among hands the evaluator scored BELOW the floor (would have passed):
        let belowFloorCount: Int
        let belowFloorMadeFloor: Int   // …of those, how many actually made it

        // 3-bucket calibration curve, keyed by estimate band.
        let buckets: [(label: String, n: Int, est: Double, real: Double, madeRate: Double)]

        var summary: String {
            var t = """
            AIArena bid calibration — \(hands) counterfactual declarer hands
              Avg estimate / realized : \(money(avgEstimate)) / \(money(avgRealized))
              Realized − estimate     : \(signedMoney(realizedMinusEstimate))  (\(bias))
              Floor make-rate (all)   : \(pct(rate(madeFloor, hands)))
              Passed-but-makeable     : \(belowFloorMadeFloor)/\(belowFloorCount) hands the evaluator
                                        scored below \(money(Double(Bidding.openingMinimum))) still made the floor (\(pct(rate(belowFloorMadeFloor, belowFloorCount))))
            CALIBRATION CURVE (estimate band → realized):
            """
            for b in buckets {
                t += "\n  \(b.label.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                t += "n=\(b.n)  est=\(money(b.est))  real=\(money(b.real))  madeFloor=\(pct(b.madeRate))"
            }
            t += "\nVERDICT: \(verdict)"
            return t
        }
        private var bias: String {
            switch realizedMinusEstimate {
            case 25_000...:        return "evaluator under-values — bid more"
            case 10_000..<25_000:  return "mildly under — small room to bid more"
            case -10_000..<10_000: return "well-calibrated"
            case -25_000 ..< -10_000: return "mildly over — risks sets"
            default:               return "evaluator over-values — bidding into sets"
            }
        }
        private var verdict: String {
            let passMakeRate = rate(belowFloorMadeFloor, belowFloorCount)
            if belowFloorCount == 0 { return "evaluator never scores a hand below the floor" }
            if passMakeRate >= 0.55 {
                return "CONSERVATIVE — most hands it would pass actually make the floor"
            }
            if passMakeRate >= 0.35 {
                return "slightly conservative — some passable hands were makeable"
            }
            return "the hands it passes mostly would NOT have made — caution justified"
        }
        private func rate(_ a: Int, _ b: Int) -> Double { b > 0 ? Double(a) / Double(b) : 0 }
        private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
        private func money(_ d: Double) -> String { String(format: "$%.0fk", d / 1000) }
        private func signedMoney(_ d: Double) -> String {
            (d >= 0 ? "+" : "-") + String(format: "$%.0fk", abs(d) / 1000)
        }
    }

    /// Deal `deals` hands; for EACH of the 4 seats, force that seat to declare
    /// at the opening floor with its best trump and play the hand to settle
    /// under competent (MC) play. Compare evaluator estimate vs realized gross.
    static func runBidCalibration(deals: Int,
                                  difficulty: MonteCarloAgent.Difficulty = .normal,
                                  baseSeed: UInt64 = 1) async -> CalibrationResult {
        var n = 0
        var sumEst = 0.0, sumReal = 0.0
        var madeFloor = 0
        var belowCount = 0, belowMade = 0
        // Buckets: [<floor, floor..<225k, >=225k]
        var bN = [0, 0, 0], bEst = [0.0, 0.0, 0.0], bReal = [0.0, 0.0, 0.0], bMade = [0, 0, 0]
        let floor = Bidding.openingMinimum

        for d in 0..<deals {
            let seed = baseSeed &+ UInt64(d) &* 2_654_435_761
            // Disable misdeal so every deal is measurable (no redeal branch).
            let deal = GameState.newHand(dealer: PlayerID(0), seed: seed,
                                         misdealRule: .disabled)
            for seat in Seats.all {
                // Evaluator estimate from the 13-card pre-widow hand.
                let view = deal.view(for: seat)
                let est = HandEvaluator.bestValuation(view: view, hand: view.myHand).expectedGross

                // Force this seat to be the declarer at the floor and play out.
                let agents: [PlayerAgent] = Seats.all.map {
                    MonteCarloAgent(name: "MC\($0.raw)", difficulty: difficulty,
                                    seed: seed &+ UInt64($0.raw) &* 97 &+ 7)
                }
                guard let realized = await playOutAsDeclarer(
                    deal: deal, declarer: seat, contract: floor, agents: agents)
                else { continue }

                n += 1
                sumEst += Double(est); sumReal += Double(realized)
                let made = realized >= floor
                if made { madeFloor += 1 }
                if est < floor {
                    belowCount += 1
                    if made { belowMade += 1 }
                }
                let b = est < floor ? 0 : (est < 225_000 ? 1 : 2)
                bN[b] += 1; bEst[b] += Double(est); bReal[b] += Double(realized)
                if made { bMade[b] += 1 }
            }
        }

        func avg(_ s: Double, _ c: Int) -> Double { c > 0 ? s / Double(c) : 0 }
        let labels = ["<floor (pass)", "floor–225k", "≥225k"]
        let buckets = (0..<3).map { i in
            (label: labels[i], n: bN[i], est: avg(bEst[i], bN[i]),
             real: avg(bReal[i], bN[i]),
             madeRate: bN[i] > 0 ? Double(bMade[i]) / Double(bN[i]) : 0)
        }

        return CalibrationResult(
            hands: n,
            avgEstimate: avg(sumEst, n),
            avgRealized: avg(sumReal, n),
            realizedMinusEstimate: avg(sumReal, n) - avg(sumEst, n),
            madeFloor: madeFloor,
            belowFloorCount: belowCount,
            belowFloorMadeFloor: belowMade,
            buckets: buckets)
    }

    /// Build the post-bidding state with `declarer` holding the bid at
    /// `contract`, then drive to `.handComplete` with `agents`. Returns the
    /// bidding team's realized gross, or nil if the hand failed to settle.
    private static func playOutAsDeclarer(deal: GameState,
                                          declarer: PlayerID,
                                          contract: Int,
                                          agents: [PlayerAgent]) async -> Int? {
        // Replicate the engine's end-of-bidding transition: declarer takes the
        // widow (16 cards), everyone else has passed, phase → namingTrump.
        var hands = deal.hands
        hands[declarer, default: []].append(contentsOf: deal.widow)
        var s = GameState(
            dealSeed: deal.dealSeed,
            dealer: deal.dealer,
            hands: hands,
            widow: [],
            phase: .namingTrump,
            toAct: declarer,
            highBid: contract,
            highBidder: declarer,
            passed: Set(Seats.all.filter { $0 != declarer }),
            bidHistory: [],
            trump: nil,
            misdealRule: .disabled,
            endgameRule: .standard,
            currentTrick: nil,
            completedTricks: [],
            capturedByTeam: [0: [], 1: []],
            matchScore: [0: 0, 1: 0],
            dealtHands: deal.dealtHands,
            dealtWidow: deal.dealtWidow)

        var steps = 0
        while s.phase != .handComplete && steps < 1_000 {
            let mover = s.toAct
            let move = await agents[mover.raw].chooseMove(from: s.view(for: mover))
            guard let ns = try? s.applying(move, by: mover) else { return nil }
            s = ns; steps += 1
        }
        guard s.phase == .handComplete, let rv = s.debugReveal() else { return nil }
        return rv.bidTeamGross
    }

    /// Quick single-hand trace for eyeballing *what* the AI does (the
    /// instrument-panel companion to the win-rate number). Prints each AI
    /// decision's phase and chosen move.
    static func traceOneHand(difficulty: MonteCarloAgent.Difficulty = .normal,
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
