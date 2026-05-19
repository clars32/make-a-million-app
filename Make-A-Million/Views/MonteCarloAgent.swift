//
//  MonteCarloAgent.swift
//  Make-a-Million
//
//  A determinized ("perfect-information") Monte Carlo agent. It is just a
//  fourth PlayerAgent — same protocol, same loop, same PlayerView the human
//  and the RandomAgent get. It never sees a hidden hand.
//
//  The recurring shape, for EVERY decision:
//    1. Sample N full worlds consistent with the PlayerView (Determinizer).
//    2. For each candidate legal move, apply it via the real engine, then
//       roll the world out with PlayoutPolicy and the engine's own rules.
//    3. Score each rollout by my partnership's net hand result (set-back
//       included — that is the real objective in Make-a-Million).
//    4. Average per candidate; pick the best. A difficulty knob adds noise.
//
//  This is the same move as a bracket Monte Carlo: sample hidden state under
//  observed constraints, evaluate, aggregate. Nothing here re-implements a
//  rule — every simulated transition goes through GameState.applying(_:by:).
//
//  HONEST STATUS: this is rung one. Wired correctly it will beat RandomAgent
//  decisively (verify with AIArena). Making it play *well and fun* against a
//  person is the iterative climb — the tuning surfaces are marked TUNE.
//
//  ENGINE BINDING: PlayerAgent ; PlayerView.* ; GameState memberwise init &
//  .applying(_:by:) & .legalMoves(for:) & .phase & .matchScore ;
//  Seats.team(of:) ; BidAction ; Move cases ; Card.{moneyValue,isMoney,
//  isSpecial,effectiveColor}. The GameState init order must match
//  AIWorld.swift's `rebuild` — keep them in sync.
//

import Foundation

struct MonteCarloAgent: PlayerAgent {

    struct Difficulty {
        /// Determinized worlds sampled per decision. More = stronger, slower.
        var samples: Int
        /// Probability of taking a deliberately non-best move (fun, not
        /// frustration). 0 = always best. TUNE per family taste.
        var blunderRate: Double
        /// Fraction of estimated hand value the agent is willing to bid up
        /// to. <1 is cautious because a missed bid is set back in full. TUNE.
        var bidAggression: Double

        static let easy   = Difficulty(samples: 8,  blunderRate: 0.25, bidAggression: 0.70)
        static let medium = Difficulty(samples: 20, blunderRate: 0.08, bidAggression: 0.85)
        static let hard   = Difficulty(samples: 40, blunderRate: 0.0,  bidAggression: 0.95)
    }

    let name: String
    let difficulty: Difficulty
    private let seedBox: RNGBox

    init(name: String = "AI",
         difficulty: Difficulty = .medium,
         seed: UInt64) {
        self.name = name
        self.difficulty = difficulty
        self.seedBox = RNGBox(seed: seed)
    }

    private var myTeamSeed: UInt64 { seedBox.nextRaw() }

    // MARK: PlayerAgent

    func chooseMove(from view: PlayerView) async -> Move {
        let legal = view.legalMoves
        precondition(!legal.isEmpty,
                     "MonteCarloAgent asked to move with no legal moves")
        if legal.count == 1 { return legal[0] }

        switch view.phase {
        case .bidding:          return decideBid(view, legal: legal)
        case .misdealDecision:  return decideMisdeal(view, legal: legal)
        case .widowDiscard:     return decideDiscard(view, legal: legal)
        case .namingTrump:      return decideByRollout(view, legal: legal,
                                                       candidates: legal)
        case .trickPlay:        return decideByRollout(view, legal: legal,
                                                       candidates: legal)
        case .handComplete:     return legal[0]
        }
    }

    // MARK: Generic evaluate-by-rollout (trick play, trump, discard)

    /// Score each candidate by mean partnership net over determinized
    /// rollouts, then pick the best (with optional blunder noise).
    private func decideByRollout(_ view: PlayerView,
                                 legal: [Move],
                                 candidates: [Move]) -> Move {
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        var totals = [Move: Double]()
        var counts = [Move: Int]()

        for s in 0..<difficulty.samples {
            var det = Determinizer(view: view, seed: myTeamSeed &+ UInt64(s))
            guard let world = det.sample() ?? det.sampleUnconstrained() else { continue }
            for cand in candidates {
                guard let afterMine = try? world.state.applying(cand, by: view.me)
                else { continue }
                let final = rollout(afterMine)
                let net = teamNet(final, myTeam: myTeam, baseline: baseline)
                totals[cand, default: 0] += Double(net)
                counts[cand, default: 0] += 1
            }
        }

        let scored = candidates
            .filter { (counts[$0] ?? 0) > 0 }
            .map { ($0, totals[$0]! / Double(counts[$0]!)) }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first else { return legal[0] }
        if shouldBlunder(), scored.count > 1 {
            // Pick a mid-pack move, not the worst — believable, not silly.
            return scored[min(scored.count - 1, 1 + intRand(scored.count - 1))].0
        }
        return best.0
    }

    // MARK: Bidding

    /// Estimate how much my side can take if I become declarer (I get the
    /// widow, discard well, name my best trump), average it over sampled
    /// deals, then bid up to a cautious fraction of that — never past what a
    /// missed bid would cost.
    private func decideBid(_ view: PlayerView, legal: [Move]) -> Move {
        let myTeam = Seats.team(of: view.me)
        let pass = legal.first { $0.isPass } ?? legal[0]
        let bidMoves = legal.compactMap { m -> (Move, Int)? in
            m.bidAmount.map { (m, $0) }
        }
        guard !bidMoves.isEmpty else { return pass }

        var valueSum = 0.0
        var n = 0
        let trials = max(6, difficulty.samples / 2)

        for s in 0..<trials {
            guard let scenario = declarerScenario(view: view,
                                                  seed: myTeamSeed &+ 7919 &+ UInt64(s))
            else { continue }
            // Declarer's edge: choose the best of the trump colors. The
            // value of a bid is the GROSS my side expects to capture as
            // declarer (what the contract test compares against), not the
            // net of opponents.
            var bestGross = -Int.max
            for color in CardColor.allCases {
                let discarded = PlayoutPolicy.move(in: scenario, seat: view.me)
                guard let afterDiscard = try? scenario.applying(discarded, by: view.me),
                      let afterTrump = try? afterDiscard.applying(.nameTrump(color),
                                                                  by: view.me)
                else { continue }
                let final = rollout(afterTrump)
                bestGross = max(bestGross, teamGross(final, team: myTeam))
            }
            if bestGross != -Int.max { valueSum += Double(bestGross); n += 1 }
        }
        guard n > 0 else { return pass }

        let estimate = valueSum / Double(n)                 // expected $ net
        let ceiling  = estimate * difficulty.bidAggression  // TUNE

        // Highest legal bid we can justify; if none, pass (the engine forces
        // the opener to the minimum if everyone passes — your family's rule —
        // so passing a hopeless hand is correct, not a deadlock).
        let affordable = bidMoves
            .filter { Double($0.1) <= ceiling }
            .max { $0.1 < $1.1 }
        return affordable?.0 ?? pass
    }

    /// A full-information state at `.widowDiscard` with me as declarer
    /// holding hand+widow (16 cards), opponents 13 each. Used only to value
    /// a hypothetical successful bid.
    private func declarerScenario(view: PlayerView, seed: UInt64) -> GameState? {
        var rng = SeededRNG(seed: seed)
        var pool = Deck.full.filter { !view.myHand.contains($0) }
        for i in stride(from: pool.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            pool.swapAt(i, j)
        }
        let widow = Array(pool.prefix(3))
        var rest = Array(pool.dropFirst(3))
        var hands: [PlayerID: [Card]] = [view.me: view.myHand + widow]
        for s in Seats.all where s != view.me {
            hands[s] = Array(rest.prefix(13)); rest.removeFirst(13)
        }
        let others = Set(Seats.all.filter { $0 != view.me })
        return GameState(
            dealSeed: 0, dealer: PlayerID(0),
            hands: hands, widow: [],
            phase: .widowDiscard, toAct: view.me,
            highBid: Bidding.openingMinimum, highBidder: view.me,
            passed: others,
            trump: nil, misdealEligible: false,
            currentTrick: nil, completedTricks: [],
            capturedByTeam: [0: [], 1: []],
            matchScore: view.matchScore)
    }

    // MARK: Widow discard (evaluated jointly with the trump that follows)

    /// The move right after a discard is *my own* trump choice, which the
    /// cheap playout can't make well. So mirror the bidding logic: for each
    /// shortlisted discard, try all four trumps, assume I (the declarer)
    /// pick the best, average that over determinized worlds, choose the
    /// discard with the highest mean.
    private func decideDiscard(_ view: PlayerView, legal: [Move]) -> Move {
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        let candidates = topDiscards(view, legal)
        guard !candidates.isEmpty else { return legal[0] }

        var totals = [Move: Double]()
        var counts = [Move: Int]()

        for s in 0..<difficulty.samples {
            var det = Determinizer(view: view, seed: myTeamSeed &+ 104_729 &+ UInt64(s))
            guard let world = det.sample() ?? det.sampleUnconstrained() else { continue }
            for disc in candidates {
                guard let afterDiscard = try? world.state.applying(disc, by: view.me)
                else { continue }
                var bestColor = -Int.max
                for color in CardColor.allCases {
                    guard let afterTrump = try? afterDiscard.applying(.nameTrump(color),
                                                                      by: view.me)
                    else { continue }
                    let final = rollout(afterTrump)
                    bestColor = max(bestColor,
                                    teamNet(final, myTeam: myTeam, baseline: baseline))
                }
                if bestColor != -Int.max {
                    totals[disc, default: 0] += Double(bestColor)
                    counts[disc, default: 0] += 1
                }
            }
        }

        let scored = candidates
            .filter { (counts[$0] ?? 0) > 0 }
            .map { ($0, totals[$0]! / Double(counts[$0]!)) }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return legal[0] }
        if shouldBlunder(), scored.count > 1 {
            return scored[min(scored.count - 1, 1 + intRand(scored.count - 1))].0
        }
        return best.0
    }

    // MARK: Misdeal

    /// Only the eligible declarer reaches this. Redeal if my own hand is
    /// near-worthless; otherwise keep it. TUNE the threshold.
    private func decideMisdeal(_ view: PlayerView, legal: [Move]) -> Move {
        let myMoney = view.myHand.reduce(0) { $0 + $1.moneyValue }
        let hasTopTrump = view.myHand.contains { $0.isSpecial }
        let bad = myMoney <= 15_000 && !hasTopTrump
        if bad { return .callMisdeal }
        return .declineMisdeal
    }

    // MARK: Widow discard candidate pruning

    /// Legal discards can number in the hundreds; MC over all of them is
    /// wasteful. Keep a heuristic shortlist: never shed money/specials when
    /// avoidable (legality enforces most of this), prefer dumping the lowest
    /// off-cards. Then MC decides among the shortlist.
    private func topDiscards(_ view: PlayerView, _ legal: [Move]) -> [Move] {
        let discards = legal.filter { $0.discardCards != nil }
        guard discards.count > 12 else { return discards }
        func cost(_ m: Move) -> Int {
            let cs = m.discardCards ?? []
            return cs.reduce(0) { acc, c in
                acc + c.moneyValue * 1000 + rank(c)
            }
        }
        return Array(discards.sorted { cost($0) < cost($1) }.prefix(12))
    }

    // MARK: Rollout + scoring

    private func rollout(_ start: GameState) -> GameState {
        var s = start
        var steps = 0
        while s.phase != .handComplete && steps < 600 {
            let mv = PlayoutPolicy.move(in: s, seat: s.toAct)
            guard let ns = try? s.applying(mv, by: s.toAct) else { break }
            s = ns
            steps += 1
        }
        return s
    }

    /// Partnership net for the settled hand: what my team gained minus what
    /// the opponents gained, relative to the score before this hand. Uses
    /// the engine's settled `matchScore`, so set-back on a missed bid is
    /// already baked in. This is the right objective for *card play* — you
    /// want your side up and theirs down.
    private func teamNet(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Int {
        let mine = (final.matchScore[myTeam] ?? 0) - (baseline[myTeam] ?? 0)
        let opp  = (final.matchScore[1 - myTeam] ?? 0) - (baseline[1 - myTeam] ?? 0)
        return mine - opp
    }

    /// GROSS money a team captured this hand: the sum of its taken tricks'
    /// settled values, before set-back and before subtracting the opponents.
    /// This — NOT the net — is what a bid is measured against: the engine's
    /// own contract test is `capturedByBidTeam >= bid`. Valuing a bid with
    /// the net systematically under-counts by roughly the opponents' capture
    /// and makes every hand look unbiddable.
    private func teamGross(_ final: GameState, team: Int) -> Int {
        (final.capturedByTeam[team] ?? [])
            .reduce(0) { $0 + GameState.trickValue($1) }
    }

    // MARK: RNG helpers

    private func shouldBlunder() -> Bool {
        guard difficulty.blunderRate > 0 else { return false }
        return Double(seedBox.nextRaw() % 10_000) / 10_000.0 < difficulty.blunderRate
    }
    private func intRand(_ upper: Int) -> Int {
        upper <= 0 ? 0 : Int(seedBox.nextRaw() % UInt64(upper))
    }
    private func rank(_ c: Card) -> Int {
        if case .colored(_, let r) = c { return r.rawValue }
        return 0
    }
}

// RNGBox already exists (RandomAgent.swift). Add a raw accessor without
// touching that file.
extension RNGBox {
    func nextRaw() -> UInt64 { UInt64(nextInt(upperBound: Int.max)) }
}
