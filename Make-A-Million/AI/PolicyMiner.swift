//
//  PolicyMiner.swift
//  Make-a-Million
//
//  Distillation instrument: PlayoutPolicy is the rollout brain — every MCTS
//  value estimate at every tier is built from its moves, so a systematic
//  misplay inside rollouts distorts the search everywhere. This miner hunts
//  those misplays the way AlphaZero-style distillation does, but in reverse:
//  the search side is the teacher and the heuristic is the student.
//
//  TEACHER = 1-ply policy improvement over PlayoutPolicy itself. From a
//  full-information mid-trick state, score every legal card by applying it
//  and rolling the TRUE world out with PlayoutPolicy, then take the argmax.
//  STUDENT = PlayoutPolicy.move on the same state. A disagreement whose
//  value gap clears the threshold is a position where the heuristic is
//  locally inconsistent with its own futures — the same differential MCTS
//  consumes per sampled world. Fixing the recurring patterns sharpens every
//  tier's search.
//
//  VARIANCE CONTROL (added after the first run): a single DETERMINISTIC
//  rollout per candidate is reproducible noise, not signal — one changed
//  card replays the whole hand, the set/made settle (±bid) dominates the
//  value, and the argmax over ~13 such chaotic values is winner's-curse
//  biased (first run: 35% "disagreement" rate, mean gap $163k — absurd on
//  its face). The teacher is therefore an ENSEMBLE: N ε-greedy perturbed
//  rollouts per candidate, seed-paired across candidates, scored by MEAN,
//  and a disagreement must ALSO win the paired sign test (teacher beats
//  student in ≥ 70% of same-seed rollout pairs). Trajectory chaos cancels;
//  persistent misplays survive.
//
//  Positions come from REAL hands: four MonteCarloAgents play normally
//  (bidding, widow, trick play) and every multi-choice trick decision the
//  game visits is mined before the agent moves on. Deterministic given
//  (hands, baseSeed).
//
//  CAVEAT: a 1-ply teacher inherits PlayoutPolicy's own future blind spots —
//  a pathology shared by every rollout future cancels out of the comparison
//  (the Bull-endplay lesson). This finds FIRST-ORDER misplays; self-
//  consistent pathologies still need handlog diagnosis.
//
//  ENGINE BINDING: GameState.{newHand, legalMoves(for:), applying(_:by:),
//  view(for:), trickWinner, phase, toAct, trump, hands, currentTrick,
//  completedTricks, matchScore} ; PlayoutPolicy.{move, tableValue,
//  tableIsBeared} ; HandLog.{token, short, colorInitial} ; Seats ; Trick ;
//  PlayedCard ; MonteCarloAgent.
//

import Foundation

enum PolicyMiner {

    nonisolated struct Pattern {
        let key: String
        var count = 0
        var totalGap = 0
        var exemplars: [String] = []
    }

    nonisolated struct Result {
        let hands: Int
        let decisions: Int        // multi-choice trick-play states mined
        let disagreements: Int    // teacher beats student by ≥ threshold
        let gapThreshold: Int
        let teacher: Teacher
        let totalRegret: Int
        let patterns: [Pattern]                                 // by totalGap desc
        let contexts: [(key: String, count: Int, totalGap: Int)] // by totalGap desc

        var summary: String {
            func m(_ v: Int) -> String { String(format: "$%.1fM", Double(v) / 1_000_000) }
            func k(_ v: Double) -> String { String(format: "$%.0fk", v / 1000) }
            let rate = decisions > 0 ? Double(disagreements) / Double(decisions) : 0
            let mean = disagreements > 0 ? Double(totalRegret) / Double(disagreements) : 0

            var t = "PolicyMiner — \(hands) hands, \(decisions) multi-choice trick decisions\n"
            t += "  teacher = mean of \(teacher.ensembleSize) ε-greedy rollouts (ε=\(teacher.epsilonPct)%), "
            t += "sign-consistency ≥ \(Int(teacher.signConsistency * 100))%\n"
            t += "  student≠teacher by ≥ \(k(Double(gapThreshold))): \(disagreements) "
            t += String(format: "(%.1f%% of decisions)   total regret %@   mean gap %@\n",
                        rate * 100, m(totalRegret), k(mean))

            t += "\nCONTEXT MARGINALS (disagreements, by total regret):\n"
            for c in contexts {
                t += "  \(c.key.padding(toLength: 44, withPad: " ", startingAt: 0))"
                t += "n=\(c.count)  total \(m(c.totalGap))\n"
            }

            t += "\nTOP PATTERNS (by total regret):\n"
            for (i, p) in patterns.prefix(12).enumerated() {
                t += String(format: "%2d. %@   n=%d  mean %@  total %@\n",
                            i + 1, p.key, p.count,
                            k(Double(p.totalGap) / Double(max(1, p.count))),
                            m(p.totalGap))
                for e in p.exemplars { t += "      " + e + "\n" }
            }
            return t
        }
    }

    /// Teacher configuration. The ε-perturbation that controls variance also
    /// BIASES the teacher: with sloppy futures, cashing money immediately is
    /// systematically overvalued (held money gets squandered by random play
    /// later). So a pattern is only trustworthy if it survives ACROSS
    /// configurations — mine at a high and a low ε and intersect the tables
    /// before believing any "the policy should cash here" finding.
    nonisolated struct Teacher {
        /// Rollouts per candidate. More = tighter means, linearly slower.
        var ensembleSize = 10
        /// Per-step probability (%) of a uniformly random legal move in an
        /// ensemble rollout. Must be high enough to branch the trajectories
        /// (variance reduction needs disagreement between members), low
        /// enough that futures stay policy-shaped.
        var epsilonPct = 15
        /// Fraction of seed-paired rollouts the teacher must win outright
        /// (sign consistency, on top of the mean gap).
        var signConsistency = 0.7

        /// The variance-control default (first-pass shopping list).
        static let standard = Teacher()
        /// Gentler perturbation, stricter consistency — for the sensitivity
        /// re-mine that separates real patterns from ε-greedy artifacts.
        static let gentle = Teacher(ensembleSize: 16, epsilonPct: 5,
                                    signConsistency: 0.75)
    }

    /// Play `hands` full hands with four MC agents at `difficulty`, mining
    /// every multi-choice trick decision along the way.
    static func mine(hands: Int,
                     difficulty: MonteCarloAgent.Difficulty = .normal,
                     baseSeed: UInt64 = 1,
                     gapThreshold: Int = 20_000,
                     teacher: Teacher = .standard) async -> Result {
        var decisions = 0
        var disagreements = 0
        var totalRegret = 0
        var patterns: [String: Pattern] = [:]
        var contexts: [String: (count: Int, totalGap: Int)] = [:]

        for h in 0..<hands {
            let seed = baseSeed &+ UInt64(h) &* 6_364_136_223_846_793_005
            var s = GameState.newHand(dealer: PlayerID(h % Seats.count),
                                      seed: seed, misdealRule: .disabled)
            let agents: [PlayerAgent] = Seats.all.map {
                MonteCarloAgent(name: "MC\($0.raw)", difficulty: difficulty,
                                seed: seed &+ UInt64($0.raw) &* 101 &+ 13)
            }

            var steps = 0
            var mined: UInt64 = 0
            while s.phase != .handComplete && steps < 1_000 {
                let seat = s.toAct
                if s.phase == .trickPlay, let trump = s.trump {
                    let legal = s.legalMoves(for: seat)
                    if legal.count > 1 {
                        decisions += 1
                        mined &+= 1
                        let decisionSeed = seed &+ mined &* 0xD1B5_4A32_D192_ED03
                        if let d = mineDecision(s, seat: seat, trump: trump,
                                                legal: legal, handIndex: h,
                                                seed: decisionSeed,
                                                gapThreshold: gapThreshold,
                                                teacher: teacher,
                                                difficulty: difficulty) {
                            disagreements += 1
                            totalRegret += d.gap
                            var p = patterns[d.patternKey, default: Pattern(key: d.patternKey)]
                            p.count += 1
                            p.totalGap += d.gap
                            if p.exemplars.count < 2 { p.exemplars.append(d.exemplar) }
                            patterns[d.patternKey] = p
                            var c = contexts[d.contextKey, default: (0, 0)]
                            c.count += 1; c.totalGap += d.gap
                            contexts[d.contextKey] = c
                        }
                    }
                }
                let move = await agents[seat.raw].chooseMove(from: s.view(for: seat))
                guard let ns = try? s.applying(move, by: seat) else { break }
                s = ns; steps += 1
            }
        }

        return Result(
            hands: hands,
            decisions: decisions,
            disagreements: disagreements,
            gapThreshold: gapThreshold,
            teacher: teacher,
            totalRegret: totalRegret,
            patterns: patterns.values.sorted { $0.totalGap > $1.totalGap },
            contexts: contexts
                .map { (key: $0.key, count: $0.value.count, totalGap: $0.value.totalGap) }
                .sorted { $0.totalGap > $1.totalGap })
    }

    // MARK: - One decision

    private struct Disagreement {
        let contextKey: String
        let patternKey: String
        let gap: Int
        let exemplar: String
    }

    private static func mineDecision(_ s: GameState,
                                     seat: PlayerID,
                                     trump: CardColor,
                                     legal: [Move],
                                     handIndex: Int,
                                     seed: UInt64,
                                     gapThreshold: Int,
                                     teacher config: Teacher,
                                     difficulty: MonteCarloAgent.Difficulty) -> Disagreement? {
        // The student is the rollout policy AS SHIPPED for this difficulty —
        // mining the bare defaults would re-flag patterns already fixed by a
        // promoted rollout lever (e.g. rolloutTopPull).
        let studentMove = PlayoutPolicy.move(in: s, seat: seat,
                                             commandingPull: difficulty.research.rolloutCommandingPull,
                                             specialEscape: difficulty.research.rolloutSpecialEscape,
                                             topPull: difficulty.rolloutTopPull,
                                             establishDuck: difficulty.research.rolloutEstablishDuck,
                                             bankWin: difficulty.research.rolloutBankWin)
        guard legal.contains(studentMove) else { return nil }

        // Ensemble values per candidate. Rollout i uses the SAME perturbation
        // seed for every candidate, so values pair across candidates by index
        // (common random numbers) and the sign test below is meaningful.
        var values: [Move: [Int]] = [:]
        for m in legal {
            var vs: [Int] = []
            vs.reserveCapacity(config.ensembleSize)
            for i in 0..<config.ensembleSize {
                let rolloutSeed = seed &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                guard let v = rolloutValue(after: m, from: s, by: seat,
                                           rolloutSeed: rolloutSeed,
                                           epsilonPct: config.epsilonPct,
                                           difficulty: difficulty) else { continue }
                vs.append(v)
            }
            if vs.count == config.ensembleSize { values[m] = vs }
        }
        guard let sVals = values[studentMove] else { return nil }
        let sMean = sVals.reduce(0, +) / sVals.count

        var teacher: (move: Move, mean: Int, vals: [Int])? = nil
        for (m, vs) in values {
            let mean = vs.reduce(0, +) / vs.count
            if teacher == nil || mean > teacher!.mean
                || (mean == teacher!.mean && m == studentMove) {
                teacher = (m, mean, vs)
            }
        }
        guard let t = teacher, t.move != studentMove else { return nil }
        let gap = t.mean - sMean
        guard gap >= gapThreshold else { return nil }
        // Paired sign test: the teacher must beat the student rollout-for-
        // rollout, not just on a mean driven by a couple of chaotic outliers.
        let wins = zip(t.vals, sVals).filter { $0 > $1 }.count
        guard Double(wins) >= config.signConsistency * Double(config.ensembleSize)
        else { return nil }
        guard let sCard = studentMove.playedCard,
              let tCard = t.move.playedCard else { return nil }
        let sVal = sMean
        let teacherValue = t.mean

        let context = contextKey(s, seat: seat, trump: trump)
        let pattern = context + " :: "
            + moveClass(sCard, state: s, seat: seat, trump: trump) + " → "
            + moveClass(tCard, state: s, seat: seat, trump: trump)

        let trickNo = s.completedTricks.count + 1
        let handTokens = (s.hands[seat] ?? []).map(HandLog.token).joined(separator: " ")
        let table = (s.currentTrick?.plays ?? [])
            .map { "\(HandLog.short($0.player)):\(HandLog.token($0.card))" }
            .joined(separator: " ")
        let led = s.currentTrick?.ledColor(trump: trump)
            .map(HandLog.colorInitial) ?? "—"
        let exemplar = "hand \(handIndex) trick \(trickNo) "
            + "seat \(HandLog.short(seat)) trump=\(HandLog.colorInitial(trump)) "
            + "led=\(led) table[\(table)]\n"
            + "        hand: \(handTokens)\n"
            + "        student \(HandLog.token(sCard)) ($\(sVal / 1000)k) → "
            + "teacher \(HandLog.token(tCard)) ($\(teacherValue / 1000)k)"

        return Disagreement(contextKey: context, patternKey: pattern,
                            gap: gap, exemplar: exemplar)
    }

    /// One ε-greedy perturbed rollout of the TRUE world under PlayoutPolicy
    /// (the difficulty's shipped rollout flags), scored as team net from
    /// `seat`'s perspective — the same value MCTS averages per sampled
    /// world, minus the sampling. The ε steps branch the trajectory so an
    /// ensemble of these explores different futures instead of replaying one
    /// chaotic line N times.
    private static func rolloutValue(after move: Move,
                                     from s: GameState,
                                     by seat: PlayerID,
                                     rolloutSeed: UInt64,
                                     epsilonPct: Int,
                                     difficulty: MonteCarloAgent.Difficulty) -> Int? {
        guard var ns = try? s.applying(move, by: seat) else { return nil }
        func policyMove(_ state: GameState, _ mover: PlayerID) -> Move {
            PlayoutPolicy.move(in: state, seat: mover,
                               commandingPull: difficulty.research.rolloutCommandingPull,
                               specialEscape: difficulty.research.rolloutSpecialEscape,
                               topPull: difficulty.rolloutTopPull,
                               establishDuck: difficulty.research.rolloutEstablishDuck,
                               bankWin: difficulty.research.rolloutBankWin)
        }
        let rng = RNGBox(seed: rolloutSeed)
        var steps = 0
        while ns.phase != .handComplete && steps < 600 {
            let mover = ns.toAct
            let mv: Move
            if rng.nextInt(upperBound: 100) < epsilonPct {
                let legal = ns.legalMoves(for: mover)
                mv = legal.isEmpty ? policyMove(ns, mover)
                                   : legal[rng.nextInt(upperBound: legal.count)]
            } else {
                mv = policyMove(ns, mover)
            }
            guard let nx = try? ns.applying(mv, by: mover) else { return nil }
            ns = nx; steps += 1
        }
        guard ns.phase == .handComplete else { return nil }
        let myTeam = Seats.team(of: seat)
        let mine = (ns.matchScore[myTeam] ?? 0) - (s.matchScore[myTeam] ?? 0)
        let opp  = (ns.matchScore[1 - myTeam] ?? 0) - (s.matchScore[1 - myTeam] ?? 0)
        return mine - opp
    }

    // MARK: - Classification

    /// Compact situation key. Coarse on purpose — buckets must recur to
    /// reveal a pattern worth patching.
    private static func contextKey(_ s: GameState,
                                   seat: PlayerID,
                                   trump: CardColor) -> String {
        guard let trick = s.currentTrick, !trick.plays.isEmpty else {
            return "leading"
        }
        let winner = GameState.trickWinner(trick, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: seat)
            && winner != seat
        let beared = PlayoutPolicy.tableIsBeared(trick.plays)
        let value = PlayoutPolicy.tableValue(trick.plays)
        let band = beared ? "beared"
                 : value == 0 ? "$0"
                 : value < 20_000 ? "<$20k" : "≥$20k"
        let last = trick.plays.count == Seats.count - 1 ? "|last" : ""
        return "follow|\(partnerWinning ? "partner-winning" : "opp-winning")|\(band)\(last)"
    }

    /// What kind of play a card is in this position: special name, or
    /// verb (lead / win / shed) + material (trump / money / plain).
    private static func moveClass(_ card: Card,
                                  state: GameState,
                                  seat: PlayerID,
                                  trump: CardColor) -> String {
        switch card {
        case .tiger: return "TIGER"
        case .bull:  return "BULL"
        case .bear:  return "BEAR"
        default: break
        }
        let verb: String
        if let trick = state.currentTrick, !trick.plays.isEmpty {
            var plays = trick.plays
            plays.append(PlayedCard(player: seat, card: card))
            let w = GameState.trickWinner(Trick(leader: trick.leader, plays: plays),
                                          trump: trump)
            verb = (w == seat) ? "win" : "shed"
        } else {
            verb = "lead"
        }
        let isTrump = card.effectiveColor(trump: trump) == trump
        let kind = card.isMoney ? (isTrump ? "trump-money" : "money")
                                : (isTrump ? "trump" : "plain")
        return "\(verb) \(kind)"
    }
}
