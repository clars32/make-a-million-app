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
        // A1 (lever `bidPartnerRead`): the scalar valuation is auction-BLIND —
        // `partnerSupport` is an unconditional ~$90k average, yet the auction
        // has already said which side of average this table sits on (partner
        // pass = weaker support, opponent bid = stronger defense). Re-center
        // the mean by the measured per-signal residuals BEFORE the set-risk
        // haircut (the haircut prices within-hand variance; this prices the
        // public evidence). The rollout bidder ignores it — `bidRolloutLean`
        // already reads the auction into its sampled deals.
        let auctionOffset = (difficulty.bidPartnerRead && !difficulty.rolloutBidEval)
            ? scalarAuctionOffset(view) : 0
        // Distribution-aware bidding (lever): the decision figure becomes the
        // make-probability quantile of rolled-out captured gross — "the contract
        // I make at least p of the time" — instead of the mean `expectedGross`,
        // so set risk is priced directly.
        //
        // The SCALAR bidder (no rollout) instead prices set risk with the
        // legible set-risk haircut: shave `bidSetRiskHaircut` of the valuation's
        // excess over the opening floor (the speculative projection a strong
        // defender beats). The cut is always < the excess, so a biddable hand
        // stays biddable — it only lowers how far above the floor we'll go.
        let scalarGross: Int = {
            let mean = valuation.expectedGross + auctionOffset
            guard difficulty.bidSetRiskHaircut > 0 else { return mean }
            let excess = max(0, mean - Bidding.openingMinimum)
            return mean - Int(difficulty.bidSetRiskHaircut * Double(excess))
        }()
        let decisionGross = difficulty.rolloutBidEval
            ? safeContractEstimate(view: view, fallback: valuation.expectedGross)
            : scalarGross
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
                // Staying-power gate (`bidEntryMargin`): we're about to make the
                // LEAD/contesting bid for our team. If our partner is still live
                // to act they'll read this bid as strength and defer (a pass is
                // permanent), so a bid we'd fold at the opponents' next raise just
                // shuts the partner out before we concede the contract anyway.
                // Only fires while BOTH a partner and an opponent are still live;
                // otherwise the signal can't mislead anyone and we bid as before.
                let myTeam = Seats.team(of: view.me)
                let partnerLive = Seats.all.contains {
                    $0 != view.me && Seats.team(of: $0) == myTeam
                        && !view.passed.contains($0)
                }
                let opponentLive = Seats.all.contains {
                    Seats.team(of: $0) != myTeam && !view.passed.contains($0)
                }
                if difficulty.bidEntryMargin > 0 && partnerLive && opponentLive {
                    // Would the opponents' minimum next raise blow past my ceiling?
                    let wouldFold = ceiling < Double(cheapestAmt + difficulty.bidEntryMargin)
                    BidGateStats.shared.recordOpportunity(flipped: wouldFold)
                    if wouldFold {
                        notes.append("staying-power: ceiling $\(Int(ceiling) / 1000)k "
                                     + "won't survive a raise to "
                                     + "$\((cheapestAmt + difficulty.bidEntryMargin) / 1000)k — "
                                     + "partner still live, passing to let them lead")
                        return passMove!
                    }
                }
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
            } else if difficulty.bidSetRiskHaircut > 0 {
                notes.append("set-risk haircut \(Int(difficulty.bidSetRiskHaircut * 100))% of excess: "
                             + "$\(valuation.expectedGross / 1000)k → $\(decisionGross / 1000)k")
            }
            if auctionOffset != 0 {
                notes.append("auction read: scalar \(auctionOffset > 0 ? "+" : "-")"
                             + "$\(abs(auctionOffset) / 1000)k from partner/opponent signals")
            }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: chosenText,
                valuationGross: decisionGross,
                ceiling: Int(ceiling), notes: notes))
        }

        return move
    }

    // MARK: - Auction-aware scalar offsets (A1)

    /// Per-signal dollar offsets for the scalar bidder, MEASURED by
    /// `AIArena.runPartnerConditionedCalibration` (July 2 2026, 320 expert
    /// forced-declarer hands, baseSeed 7 — per-band residual of realized team
    /// gross vs the blind estimate):
    ///   partner <floor −$30k (make-at-est 25%) / floor–225k −$20k (40%)
    ///   / ≥225k +$38k (71%); max-opponent <225k +$37k (67%) / ≥225k +$2k (50%).
    /// Mapping to the OBSERVABLE signals: a pass mostly lands in the weak
    /// bands (−$25k mix, taken at full size — it is the anti-set direction,
    /// the documented Item-1 pain); a bid only bounds the seat's valuation
    /// from below, so the positive offsets are DAMPED (a low bid mixes the
    /// −$20k and +$38k bands; positives also raise bids and therefore set
    /// risk, and the partner/opponent bucketings share playouts, so summing
    /// raw residuals would double-count the covariance). An opponent BID
    /// needs no correction: the unconditional calibration is already
    /// dominated by contested tables (+$2k ≈ 0).
    static let partnerPassedOffset  = -25_000
    static let partnerBidOffset     =  10_000
    static let opponentPassedOffset =  12_000  // per seat; both passed ≈ +$24k
    static let opponentBidOffset    =  0

    /// The auction evidence available right now, priced in dollars. "Ever bid"
    /// outranks a later fold (they showed real cards, then hit their ceiling);
    /// a seat that never acted contributes 0 (the unconditional average the
    /// evaluator already assumes).
    func scalarAuctionOffset(_ view: PlayerView) -> Int {
        var everBid: Set<PlayerID> = []
        for rec in view.bidHistory {
            if case .bid = rec.action { everBid.insert(rec.player) }
        }
        var offset = 0
        let partner = Seats.partner(of: view.me)
        if everBid.contains(partner) {
            offset += Self.partnerBidOffset
        } else if view.passed.contains(partner) {
            offset += Self.partnerPassedOffset
        }
        for opp in Seats.all where Seats.team(of: opp) != Seats.team(of: view.me) {
            if everBid.contains(opp) {
                offset += Self.opponentBidOffset
            } else if view.passed.contains(opp) {
                offset += Self.opponentPassedOffset
            }
        }
        return offset
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
            // CLOSING BID (B4, July 2026, lever `bidToClose`): when the
            // decision figure itself covers what we still need, MAKING this
            // contract ends the match — the shrink below would pass a
            // match-winning contract to the opponents just when it matters
            // most (the leader's conservatism is about avoiding late sets,
            // but a make here means there is no "later"). Keep the normal
            // ceiling; never inflate it, so a hand we wouldn't bid mid-match
            // still passes.
            if difficulty.bidToClose, base >= 1_000_000.0 - mine {
                return base
            }
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

    /// Candidate 3-card discards for the declarer's 16-card hand under `trump`:
    /// engine-legal (`GameState.legalWidowDiscards` — the same generator the
    /// discard phase runs), shortlisted for evaluation as the cheapest few by
    /// `discardCost` PLUS the cheapest suit-EMPTYING combo per side color. The
    /// second group is the fix for a real leak: a discard that voids a side
    /// suit can rank "expensive" by raw rank (a singleton 7 loses the cost sort
    /// to three 2-3-4s) yet win on the evaluator's void value — cost order
    /// alone drops exactly the combos worth finding. Shared by `decideDiscard`
    /// and the joint trump naming in `decideTrump`.
    func discardCandidates(hand: [Card], trump: CardColor) -> [[Card]] {
        let legal = GameState.legalWidowDiscards(from: hand, trump: trump)
        guard !legal.isEmpty else { return [] }
        let byCost = legal.map { ($0, discardCost($0)) }.sorted { $0.1 < $1.1 }
        var out: [[Card]] = []
        var seen: Set<Set<Card>> = []
        func add(_ combo: [Card]) {
            if seen.insert(Set(combo)).inserted { out.append(combo) }
        }
        for (combo, _) in byCost.prefix(max(8, difficulty.trickCandidates * 2)) {
            add(combo)
        }
        // Suit-emptying candidates: for each non-trump color whose ENTIRE
        // holding is small enough to throw (≤3 cards), the cheapest legal
        // combo containing all of it. When money/specials of the color make
        // emptying illegal, no legal combo contains the full set and the
        // search finds nothing — correctly skipped.
        for color in CardColor.allCases where color != trump {
            let ofColor = Set(hand.filter { $0.effectiveColor(trump: trump) == color })
            guard (1...3).contains(ofColor.count) else { continue }
            if let cheapest = byCost.first(where: { ofColor.isSubset(of: Set($0.0)) })?.0 {
                add(cheapest)
            }
        }
        return out
    }

    func decideDiscard(_ view: PlayerView, legal: [Move]) -> Move {
        // Trump was named in the previous phase — score each candidate discard
        // against the known trump. The candidate set is the shared shortlist
        // (cheapest by cost + suit-emptying combos); moves are matched back to
        // the engine's legal list by content so combo ordering can't drift.
        guard let trump = view.trump else { return legal[0] }

        var moveFor: [Set<Card>: Move] = [:]
        for m in legal {
            if let cs = m.discardCards { moveFor[Set(cs)] = m }
        }
        guard !moveFor.isEmpty else { return legal[0] }

        var best: (Move, Int) = (legal[0], Int.min)
        for cards in discardCandidates(hand: view.myHand, trump: trump) {
            guard let move = moveFor[Set(cards)] else { continue }
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
        // JOINT trump + discard (lever `jointTrumpNaming`): the hand that
        // PLAYS is the 13 kept after the discard, so each color is scored by
        // the BEST 13-card keep it allows. The raw 16-card valuation both
        // inflates trump length with cards about to be discarded and cannot
        // see a void the discard would create — so it can name the wrong
        // color when two are close. Discard legality is the engine's
        // (`legalWidowDiscards`, via the shared shortlist); the real discard
        // is chosen next phase by the same evaluator, so naming and
        // discarding agree on the same argmax.
        if difficulty.jointTrumpNaming {
            var best: (move: Move, score: Int)? = nil
            for m in legal {
                guard case .nameTrump(let color) = m else { continue }
                var colorBest = Int.min
                for combo in discardCandidates(hand: view.myHand, trump: color) {
                    var keep = view.myHand
                    for c in combo {
                        if let i = keep.firstIndex(of: c) { keep.remove(at: i) }
                    }
                    let s = HandEvaluator.evaluate(view: view, hand: keep,
                                                   assumingTrump: color,
                                                   tables: difficulty.evaluatorTables)
                    if s > colorBest { colorBest = s }
                }
                if colorBest == Int.min {
                    // Defensive (non-16-card hand): raw valuation.
                    colorBest = HandEvaluator.evaluate(view: view, hand: view.myHand,
                                                       assumingTrump: color,
                                                       tables: difficulty.evaluatorTables)
                }
                if best == nil || colorBest > best!.score { best = (m, colorBest) }
            }
            if let best { return best.move }
        }

        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand,
                                                    tables: difficulty.evaluatorTables)
        // Find the .nameTrump move corresponding to bestTrump.
        for m in legal {
            if case .nameTrump(let c) = m, c == valuation.bestTrump { return m }
        }
        return legal[0]
    }

}
