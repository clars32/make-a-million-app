//
//  MonteCarloAgent+Bidding.swift
//  Make-a-Million
//
//  Bidding, misdeal vote, widow discard, and trump naming decisions.
//  Split out of MonteCarloAgent.swift; same type via `extension MonteCarloAgent`.
//

import Foundation

extension MonteCarloAgent {

    // MARK: - Misdeal decision

    /// Agreement-mode misdeal: vote to KEEP the hand (`declineMisdeal`) when it
    /// is worth playing, else agree to the redeal (`callMisdeal`). The redeal is
    /// triggered by ANY seat being money-poor — so a strong hand of ours must
    /// not be thrown away just because someone else is short (the old `legal[0]`
    /// agreed to EVERY redeal, even holding a monster). In automatic mode the
    /// only legal move is the forced redeal, so we return it.
    func decideMisdeal(_ view: PlayerView, legal: [Move]) -> Move {
        guard legal.contains(.declineMisdeal) else {
            return legal.first ?? .callMisdeal      // automatic mode: forced redeal
        }
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // A hand that values at or above the opening floor is a real declare
        // candidate — keep it. Below that, a fresh deal is the better gamble.
        return valuation.expectedGross >= Bidding.openingMinimum
            ? .declineMisdeal
            : .callMisdeal
    }

    // MARK: - Bidding

    func decideBid(_ view: PlayerView, legal: [Move]) -> Move {
        // Split legal moves into pass + bids (sorted by amount asc).
        let passMove = legal.first { $0.isPass }
        let bidMoves: [(Move, Int)] = legal.compactMap { m in
            if let amt = m.bidAmount { return (m, amt) }; return nil
        }.sorted { $0.1 < $1.1 }

        // Hand value as if I become declarer with best trump.
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // Distribution-aware bidding (lever): the decision figure becomes the
        // make-probability quantile of rolled-out captured gross — "the contract
        // I make at least p of the time" — instead of the mean `expectedGross`,
        // so set risk is priced directly.
        let decisionGross = difficulty.rolloutBidEval
            ? safeContractEstimate(view: view, fallback: valuation.expectedGross)
            : valuation.expectedGross
        let rawGross = Double(decisionGross)

        // The aggression multiplier is a heuristic stretch over the MEAN
        // (scalar) valuation. The rollout figure already prices set risk (it's
        // a make-probability quantile), so multiplying it by 1.05 just commits
        // ABOVE the agent's own safe level — exactly the war over-bids that get
        // set (handlog 7/8: fighting to a contract its trick-1 search rated as
        // already lost). So drop the multiplier for the rollout bidder.
        let aggressionFactor = (difficulty.rolloutBidEval && difficulty.bidRolloutDropAggression)
            ? 1.0
            : difficulty.bidAggression

        // Match awareness — see below.
        let ceiling = applyMatchAwareness(
            base: rawGross * aggressionFactor,
            view: view)

        var notes: [String] = []
        let partnerHighBidder = {
            if let hb = view.highBidder, hb != view.me,
               Seats.team(of: hb) == Seats.team(of: view.me) { return true }
            return false
        }()

        // The decision itself, captured so we can trace it before returning.
        let move: Move = {
            // ---- Forced opener: pass is not legal, must bid.
            if passMove == nil {
                // Bid the minimum legal amount. Forced openings happen on
                // weak hands; we don't speculate higher than required.
                notes.append("forced opener — bidding the minimum")
                return bidMoves.first?.0 ?? legal[0]
            }

            guard let (cheapestBid, cheapestAmt) = bidMoves.first else {
                return passMove!
            }

            // ---- Partner is current high bidder: defer unless decisively stronger.
            if let hb = view.highBidder, let hbAmount = view.highBid,
               Seats.team(of: hb) == Seats.team(of: view.me), hb != view.me {
                // Once BOTH opponents have passed, the contract is the team's to
                // keep no matter who declares — raising our own partner only
                // inflates the contract (and the set-back risk) for zero gain.
                // Suppress the override. Exception: a partner sitting on the
                // forced minimum open ($175k) may be a weak/forced opener (they
                // didn't choose to bid that high), so allow a single rescue.
                let opponentsLive = Seats.all.contains {
                    Seats.team(of: $0) != Seats.team(of: view.me)
                        && !view.passed.contains($0)
                }
                if !opponentsLive && hbAmount > Bidding.openingMinimum {
                    notes.append("both opponents passed — not bidding partner up "
                                 + "($\(hbAmount / 1000)k already holds the contract)")
                    return passMove!
                }
                // Override threshold scales with partnerRespect.
                // respect 1.0 → need rawGross >= hbAmount + $80k
                // respect 0.0 → need rawGross >  hbAmount
                let extraNeeded = Int(80_000.0 * difficulty.partnerRespect)
                let threshold = hbAmount + extraNeeded
                notes.append("partner holds the bid ($\(hbAmount / 1000)k); "
                             + "override needs valuation > $\(threshold / 1000)k")
                if decisionGross > threshold
                    && Double(cheapestAmt) <= ceiling {
                    return cheapestBid
                }
                return passMove!
            }

            // ---- Opponent or no one has high bid: bid the minimum legal raise
            // that fits the ceiling, otherwise pass. Strong players don't bid
            // themselves up.
            if Double(cheapestAmt) <= ceiling {
                // Optional jump-bid on monster hands: if my estimate is FAR
                // above the cheapest legal bid (≥ 1.5× the cheapest), and
                // aggression is high, step up one tier to telegraph strength
                // to partner. Most of the time we still bid the minimum.
                if difficulty.bidAggression >= 0.85
                    && rawGross >= Double(cheapestAmt) * 1.50
                    && bidMoves.count >= 2
                    && Double(bidMoves[1].1) <= ceiling
                    && shouldJumpBid() {
                    notes.append("jump-bid: valuation ≥ 1.5× the minimum raise")
                    return bidMoves[1].0
                }
                return cheapestBid
            }
            notes.append("cheapest legal bid $\(cheapestAmt / 1000)k exceeds ceiling — pass")
            return passMove!
        }()

        if AIDecisionTrace.shared.isEnabled {
            if partnerHighBidder && notes.isEmpty {
                notes.append("partner holds the bid")
            }
            let chosenText = move.isPass
                ? "pass"
                : move.bidAmount.map { "$\($0 / 1000)k" } ?? "?"
            if difficulty.rolloutBidEval {
                notes.append("rollout bid: P(make)=\(Int(difficulty.bidMakeProbability * 100))% "
                             + "contract $\(decisionGross / 1000)k "
                             + "(mean valuation $\(valuation.expectedGross / 1000)k)")
            }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: chosenText,
                valuationGross: decisionGross,
                ceiling: Int(ceiling), notes: notes))
        }

        return move
    }

    /// Tighten the ceiling when our team is near the $1M finish line;
    /// loosen it when we're far behind and opponents are near it.
    /// Returns the adjusted ceiling.
    func applyMatchAwareness(base: Double, view: PlayerView) -> Double {
        guard difficulty.matchAwareness > 0 else { return base }
        let myTeam = Seats.team(of: view.me)
        let mine = Double(view.matchScore[myTeam] ?? 0)
        let theirs = Double(view.matchScore[1 - myTeam] ?? 0)
        // Conservative if we're close to winning.
        if mine >= 750_000 {
            let progress = min(1.0, (mine - 750_000) / 250_000)
            let shrink = 0.30 * progress * difficulty.matchAwareness
            return base * (1.0 - shrink)
        }
        // Aggressive if we're well behind AND they're approaching the goal.
        if theirs >= 700_000 && theirs - mine >= 150_000 {
            let urgency = min(1.0, (theirs - 700_000) / 300_000)
            let stretch = 0.20 * urgency * difficulty.matchAwareness
            return base * (1.0 + stretch)
        }
        return base
    }

    func shouldJumpBid() -> Bool {
        // 35% chance, so jump bids are an occasional flavour, not standard.
        seedBox.nextInt(upperBound: 100) < 35
    }

    // MARK: - Distribution-aware bid evaluation (rolloutBidEval)

    /// The make-probability quantile of the captured-gross distribution if I
    /// declared this hand: sample `bidRolloutWorlds` full deals from the
    /// auction, play each out with me declaring, and return the contract level
    /// I capture in at least `bidMakeProbability` of them. Falls back to the
    /// scalar `expectedGross` if no rollout completed.
    func safeContractEstimate(view: PlayerView, fallback: Int) -> Int {
        let worlds = max(1, difficulty.bidRolloutWorlds)
        var grosses: [Int] = []
        grosses.reserveCapacity(worlds)
        for w in 0..<worlds {
            if let g = rolloutDeclareGross(view: view,
                                           seed: seedBox.nextRaw() &+ UInt64(w)) {
                grosses.append(g)
            }
        }
        guard !grosses.isEmpty else { return fallback }
        grosses.sort()
        // safeContract = the value X with P(captured >= X) ≈ p. With grosses
        // sorted ascending, the element at rank floor((1-p)·n) has a ≥ p tail
        // at or above it.
        let p = min(0.95, max(0.05, difficulty.bidMakeProbability))
        let idx = Int((1.0 - p) * Double(grosses.count))
        return grosses[max(0, min(grosses.count - 1, idx))]
    }

    /// One bid-time rollout: sample the hidden hands + widow, set me up as the
    /// declarer (name trump with the real heuristic, discard the cheapest legal
    /// three), play the hand out greedily, and return my team's captured gross.
    /// The contract amount doesn't affect play, so a placeholder bid is fine.
    func rolloutDeclareGross(view: PlayerView, seed: UInt64) -> Int? {
        guard let deal = sampleBidDeal(view: view, seed: seed) else { return nil }
        var hands = deal.hands
        hands[view.me] = view.myHand + deal.widow          // the bidder takes the 16
        var s = GameState(
            dealSeed: 0, dealer: PlayerID(0),
            hands: hands, widow: [],
            phase: .namingTrump, toAct: view.me,
            highBid: Bidding.openingMinimum, highBidder: view.me,
            passed: Set(Seats.all.filter { $0 != view.me }),
            bidHistory: [], trump: nil, discardAnnouncement: nil,
            misdealRule: .disabled, endgameRule: .standard,
            houseRules: view.houseRules,
            currentTrick: nil, completedTricks: [], capturedByTeam: [0: [], 1: []],
            matchScore: view.matchScore, dealtHands: [:], dealtWidow: [])

        let trumpMove = decideTrump(s.view(for: view.me),
                                    legal: s.legalMoves(for: view.me))
        guard let s1 = try? s.applying(trumpMove, by: view.me) else { return nil }
        s = s1
        let discardLegal = s.legalMoves(for: view.me)
        // Cost each discard once (not twice per comparison) and take the min.
        let discardMove = discardLegal
            .map { ($0, discardCost($0.discardCards ?? [])) }
            .min { $0.1 < $1.1 }?.0
            ?? discardLegal.first
        guard let dm = discardMove, let s2 = try? s.applying(dm, by: view.me) else {
            return nil
        }
        s = s2

        var steps = 0
        while s.phase != .handComplete && steps < 600 {
            let mv = policyMove(in: s, seat: s.toAct)
            guard let ns = try? s.applying(mv, by: s.toAct) else { break }
            s = ns
            steps += 1
        }
        let myTeam = Seats.team(of: view.me)
        return (s.capturedByTeam[myTeam] ?? []).reduce(0) { $0 + GameState.trickValue($1) }
    }

    /// Sample the 3 hidden hands + 3 widow cards from the deck minus my known
    /// hand. With `bidRolloutLean` the 39 dealt cards are biased by the AUCTION
    /// (strong cards drift to seats that bid, weak to passers) so a contested
    /// auction makes opponents as strong as their bidding implies; the 3 widow
    /// cards are reserved at random first (the widow is independent of the
    /// auction). Uniform when the lean is off or `bidLeanStrength == 0`.
    /// Internal so the lean is statistically testable. nil only on a deck
    /// bookkeeping mismatch (e.g. called outside bidding) — never in practice.
    func sampleBidDeal(view: PlayerView,
                       seed: UInt64) -> (hands: [PlayerID: [Card]], widow: [Card])? {
        let mine = Set(view.myHand)
        var pool = Deck.full.filter { !mine.contains($0) }
        guard pool.count == 13 * (Seats.count - 1) + 3 else { return nil }   // 42
        var rng = SeededRNG(seed: seed)
        func shuffle(_ a: inout [Card]) {
            for i in stride(from: a.count - 1, to: 0, by: -1) {
                a.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
        }
        shuffle(&pool)
        let others = Seats.all.filter { $0 != view.me }

        // The widow is 3 random cards, dealt independently of the bidding.
        let widow = Array(pool.suffix(3))
        let deal = Array(pool.prefix(pool.count - 3))     // 39 to distribute

        var hands: [PlayerID: [Card]] = [view.me: view.myHand]
        for s in others { hands[s] = [] }

        if difficulty.bidRolloutLean && difficulty.bidLeanStrength > 0 {
            let lean = BidLean.bySeat(view: view)
            for card in deal {
                let need = others.filter { (hands[$0]?.count ?? 0) < 13 }
                let pick = weightedSeat(need, card: card, lean: lean,
                                        strength: difficulty.bidLeanStrength, rng: &rng)
                hands[pick, default: []].append(card)
            }
        } else {
            var cursor = 0
            for s in others { hands[s] = Array(deal[cursor ..< cursor + 13]); cursor += 13 }
        }
        return (hands, widow)
    }

    /// Pick a seat for `card`, weighted by the shared `BidLean` model (>1 when a
    /// strong card meets a bidder, or a weak card a passer). Among the seats that
    /// still need cards, so counts stay exact. Trump is unnamed at bid time, so
    /// the model's same-color bonus is inactive (`trump: nil`).
    func weightedSeat(_ seats: [PlayerID], card: Card,
                              lean: [PlayerID: Double], strength: Double,
                              rng: inout SeededRNG) -> PlayerID {
        guard seats.count > 1 else { return seats.first ?? PlayerID(0) }
        let weights = seats.map {
            BidLean.weight(card: card, seat: $0, lean: lean, strength: strength, trump: nil)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return seats[0] }
        let r = Double(rng.next() % 1_000_000) / 1_000_000.0 * total
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if r <= acc { return seats[i] }
        }
        return seats[seats.count - 1]
    }

    // MARK: - Widow discard (trump already known)

    func decideDiscard(_ view: PlayerView, legal: [Move]) -> Move {
        // Trump was named in the previous phase — score each legal discard
        // against the known trump rather than searching jointly.
        guard let trump = view.trump else { return legal[0] }

        let discards = legal.compactMap { m -> (Move, [Card])? in
            if let cs = m.discardCards { return (m, cs) }; return nil
        }
        guard !discards.isEmpty else { return legal[0] }

        // Shortlist by ascending cost: the engine already enforces the
        // protection ordering (specials, trump, money), so cheap = low-rank
        // off-color trash, which is exactly the right thing to throw away.
        let ranked = discards
            .map { ($0.0, $0.1, discardCost($0.1)) }
            .sorted { $0.2 < $1.2 }
            .prefix(max(8, difficulty.trickCandidates * 2))

        var best: (Move, Int) = (legal[0], Int.min)
        for (move, cards, _) in ranked {
            var hand = view.myHand
            for c in cards { if let i = hand.firstIndex(of: c) { hand.remove(at: i) } }
            let score = HandEvaluator.evaluate(view: view, hand: hand, assumingTrump: trump,
                                               tables: difficulty.evaluatorTables)
            if score > best.1 { best = (move, score) }
        }
        return best.0
    }

    func discardCost(_ cards: [Card]) -> Int {
        cards.reduce(0) { acc, c in
            acc + c.moneyValue * 1_000 + cardRank(c)
        }
    }

    // MARK: - Naming trump

    func decideTrump(_ view: PlayerView, legal: [Move]) -> Move {
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // Find the .nameTrump move corresponding to bestTrump.
        for m in legal {
            if case .nameTrump(let c) = m, c == valuation.bestTrump { return m }
        }
        return legal[0]
    }

}
