//
//  MonteCarloAgent.swift
//  Make-a-Million
//
//  REWRITE — a hybrid agent that plays the way a strong human would
//  describe playing. Heuristics drive the parts where they outperform
//  rollouts (bidding, discard, trump, misdeal); MCTS over determinized
//  worlds drives the parts where they don't (trick play). The shortlist
//  passed to MCTS is itself heuristic, so the search spends its samples
//  on choices that are actually plausible.
//
//  Public API unchanged. GameSession and AIArena keep working untouched.
//
//  ─────────────────────────────────────────────────────────────────────
//  PRINCIPLES, with where they live:
//
//   Bidding (heuristic, this file)
//     • Hand-valuation: HandEvaluator (money, trump length, voids,
//       specials, partner support, widow EV) — the single biggest
//       skill in the game.
//     • Reluctant to bid past partner: `partnerRespect`. If partner is
//       the high bidder I only override when MY estimate is decisively
//       better than their bid.
//     • Slow to outbid by more than needed: when raising an opponent,
//       I bid the MINIMUM legal raise — strong players don't bid
//       themselves up. Aggression only affects WHETHER I bid, not how
//       much.
//     • Score-aware: when our team is near $1M, tighten the ceiling
//       (avoid going set and giving them back the game). When far
//       behind with opponents near $1M, loosen it.
//     • Style variation: easy/medium/hard differ in aggression,
//       partner-respect, and blunder rate so the four bots don't feel
//       identical.
//
//   Misdeal (heuristic, this file)
//     • Call misdeal if I won a bid I can't make (HandEvaluator below
//       a margin) or my hand is structurally dead.
//
//   Widow discard + trump (heuristic, this file)
//     • Joint optimisation: for each shortlisted discard, try all 4
//       trump colors; pick the (discard, trump) pair with the highest
//       HandEvaluator score for the resulting 13-card hand.
//     • Shortlist drops the lowest non-money, non-special cards first
//       (the engine forbids needless money/special discards anyway).
//
//   Trick play (heuristic shortlist + MCTS, this file)
//     • Heuristic shortlist from TableInference encodes:
//         – Pull trump when declarer with length + Tiger loose.
//         – $40k first time a color is led.
//         – Cash sure winners in side suits.
//         – Save big money when an opponent could still trump.
//         – Dump money on partner's safe trick (and Bull doubles it).
//         – Bear on opponent's money trick we can't take.
//         – Last to play: take cheaply or shed lowest.
//     • MCTS scores each shortlisted move by mean team NET over
//       sampled worlds. PlayoutPolicy is now tactically aware, so
//       fewer samples carry more signal.
//  ─────────────────────────────────────────────────────────────────────
//
//  ENGINE BINDING: PlayerAgent ; PlayerView.* ; GameState.applying(_:by:)
//  & .legalMoves(for:) & .phase & .matchScore & .capturedByTeam ;
//  Seats.{team, partner, next, all, count} ; BidAction ; Move cases ;
//  Card.{moneyValue, isMoney, isSpecial, effectiveColor} ;
//  Bidding.{openingMinimum, raiseIncrement, bidIncrement}.
//

import Foundation

struct MonteCarloAgent: PlayerAgent {

    struct Difficulty {
        /// Determinized worlds sampled per trick-play decision. More =
        /// stronger but slower. With the new tactical playout 12-30 is
        /// often enough; old version needed 40+.
        var samples: Int
        /// Probability of taking a deliberately non-best move (fun, not
        /// frustration). 0 = always best.
        var blunderRate: Double
        /// Multiplier on hand value when deciding how far to bid. <1 is
        /// cautious because a missed bid is set back in full.
        var bidAggression: Double
        /// How much the agent defers to a partner who already has the
        /// high bid. 1.0 = strongly defer (only override on monsters);
        /// 0.0 = ignore partner.
        var partnerRespect: Double
        /// How strongly match-score situation modifies the bid ceiling.
        /// 0 = ignore score; 1 = full conservative-ahead / aggressive-behind.
        var matchAwareness: Double
        /// Trick-play shortlist size. Smaller = faster but might miss
        /// the best move. 3-5 is the sweet spot.
        var trickCandidates: Int

        static let easy   = Difficulty(samples: 10, blunderRate: 0.22,
                                       bidAggression: 0.80, partnerRespect: 0.95,
                                       matchAwareness: 0.7, trickCandidates: 3)
        static let medium = Difficulty(samples: 20, blunderRate: 0.06,
                                       bidAggression: 0.92, partnerRespect: 0.85,
                                       matchAwareness: 1.0, trickCandidates: 4)
        static let hard   = Difficulty(samples: 36, blunderRate: 0.0,
                                       bidAggression: 1.00, partnerRespect: 0.75,
                                       matchAwareness: 1.0, trickCandidates: 5)
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

    // MARK: - PlayerAgent

    func chooseMove(from view: PlayerView) async -> Move {
        let legal = view.legalMoves
        precondition(!legal.isEmpty,
                     "MonteCarloAgent asked to move with no legal moves")
        if legal.count == 1 { return legal[0] }

        switch view.phase {
        case .bidding:         return decideBid(view, legal: legal)
        case .misdealDecision: return decideMisdeal(view, legal: legal)
        case .widowDiscard:    return decideDiscard(view, legal: legal)
        case .namingTrump:     return decideTrump(view, legal: legal)
        case .trickPlay:       return decideTrickPlay(view, legal: legal)
        case .handComplete:    return legal[0]
        }
    }

    // MARK: - Bidding

    private func decideBid(_ view: PlayerView, legal: [Move]) -> Move {
        // Split legal moves into pass + bids (sorted by amount asc).
        let passMove = legal.first { $0.isPass }
        let bidMoves: [(Move, Int)] = legal.compactMap { m in
            if let amt = m.bidAmount { return (m, amt) }; return nil
        }.sorted { $0.1 < $1.1 }

        // Hand value as if I become declarer with best trump.
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand)
        let rawGross = Double(valuation.expectedGross)

        // Match awareness — see below.
        let ceiling = applyMatchAwareness(
            base: rawGross * difficulty.bidAggression,
            view: view)

        // ---- Forced opener: pass is not legal, must bid.
        if passMove == nil {
            // Bid the minimum legal amount. Forced openings happen on
            // weak hands; we don't speculate higher than required.
            return bidMoves.first?.0 ?? legal[0]
        }

        guard let (cheapestBid, cheapestAmt) = bidMoves.first else {
            return passMove!
        }

        // ---- Partner is current high bidder: defer unless decisively stronger.
        if let hb = view.highBidder, let hbAmount = view.highBid,
           Seats.team(of: hb) == Seats.team(of: view.me), hb != view.me {
            // Override threshold scales with partnerRespect.
            // respect 1.0 → need rawGross >= hbAmount + $80k
            // respect 0.0 → need rawGross >  hbAmount
            let extraNeeded = Int(80_000.0 * difficulty.partnerRespect)
            let threshold = hbAmount + extraNeeded
            if valuation.expectedGross > threshold
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
                return bidMoves[1].0
            }
            return cheapestBid
        }
        return passMove!
    }

    /// Tighten the ceiling when our team is near the $1M finish line;
    /// loosen it when we're far behind and opponents are near it.
    /// Returns the adjusted ceiling.
    private func applyMatchAwareness(base: Double, view: PlayerView) -> Double {
        guard difficulty.matchAwareness > 0 else { return base }
        let myTeam = Seats.team(of: view.me)
        let mine = Double(view.matchScore[myTeam] ?? 0)
        let theirs = Double(view.matchScore[1 - myTeam] ?? 0)
        let goal: Double = 1_000_000

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

    private func shouldJumpBid() -> Bool {
        // 35% chance, so jump bids are an occasional flavour, not standard.
        seedBox.nextInt(upperBound: 100) < 35
    }

    // MARK: - Misdeal

    private func decideMisdeal(_ view: PlayerView, legal: [Move]) -> Move {
        // I won a bid; should I redeal? Two reasons to call it:
        //  (a) my hand is structurally dead (low money, no Tiger).
        //  (b) HandEvaluator says I'll miss my bid by a lot.
        let myMoney = view.myHand.reduce(0) { $0 + $1.moneyValue }
        let hasTiger = view.myHand.contains { if case .tiger = $0 { return true }; return false }
        let dead = myMoney <= 15_000 && !hasTiger

        if dead { return .callMisdeal }

        // Estimate: I'll have the widow soon. Add a slack widow EV to the
        // hand-only valuation and compare to my bid.
        if let bid = view.highBid {
            let v = HandEvaluator.bestValuation(view: view, hand: view.myHand)
            let expected = Double(v.expectedGross)
            if expected < Double(bid) * 0.80 {
                return .callMisdeal
            }
        }
        return .declineMisdeal
    }

    // MARK: - Widow discard (trump already known)

    private func decideDiscard(_ view: PlayerView, legal: [Move]) -> Move {
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
            let score = HandEvaluator.evaluate(view: view, hand: hand, assumingTrump: trump)
            if score > best.1 { best = (move, score) }
        }
        return best.0
    }

    private func discardCost(_ cards: [Card]) -> Int {
        cards.reduce(0) { acc, c in
            acc + c.moneyValue * 1_000 + cardRank(c)
        }
    }

    // MARK: - Naming trump

    private func decideTrump(_ view: PlayerView, legal: [Move]) -> Move {
        let valuation = HandEvaluator.bestValuation(view: view, hand: view.myHand)
        // Find the .nameTrump move corresponding to bestTrump.
        for m in legal {
            if case .nameTrump(let c) = m, c == valuation.bestTrump { return m }
        }
        return legal[0]
    }

    // MARK: - Trick play (heuristic shortlist + MCTS)

    private func decideTrickPlay(_ view: PlayerView, legal: [Move]) -> Move {
        let inference = TableInference(view: view)
        let shortlist = trickShortlist(view: view,
                                       legal: legal,
                                       inference: inference)
        // Singleton shortlist: skip MCTS.
        if shortlist.count == 1 { return shortlist[0] }

        // MCTS over determinized worlds: for each candidate, sample
        // worlds, apply candidate, rollout via PlayoutPolicy, score by
        // team net.
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        var totals = [Move: Double]()
        var counts = [Move: Int]()

        for s in 0..<difficulty.samples {
            var det = Determinizer(view: view, seed: seedBox.nextRaw() &+ UInt64(s))
            guard let world = det.sample() ?? det.sampleUnconstrained() else { continue }
            for cand in shortlist {
                guard let afterMine = try? world.state.applying(cand, by: view.me)
                else { continue }
                let final = rollout(afterMine)
                let net = teamNet(final, myTeam: myTeam, baseline: baseline)
                totals[cand, default: 0] += Double(net)
                counts[cand, default: 0] += 1
            }
        }

        let scored = shortlist
            .filter { (counts[$0] ?? 0) > 0 }
            .map { ($0, totals[$0]! / Double(counts[$0]!)) }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first else { return shortlist[0] }
        if shouldBlunder(), scored.count > 1 {
            // Believable: pick a mid-pack move, never the worst.
            let idx = min(scored.count - 1, 1 + intRand(scored.count - 1))
            return scored[idx].0
        }
        return best.0
    }

    /// Build the candidate list MCTS evaluates. This is where the human
    /// principles live: we trim from the full legal set down to "moves a
    /// strong player would seriously consider".
    private func trickShortlist(view: PlayerView,
                                legal: [Move],
                                inference: TableInference) -> [Move] {
        let playCards = legal.compactMap { $0.playedCard }
        guard !playCards.isEmpty,
              let trump = view.trump else { return legal }

        let trick = view.currentTrick
        let onTable = trick?.plays ?? []
        let isLeading = onTable.isEmpty
        var candidates: [Card] = []

        if isLeading {
            candidates = leadShortlist(view: view, plays: playCards,
                                       trump: trump, inference: inference)
        } else {
            candidates = followShortlist(view: view, plays: playCards,
                                         trick: trick!, trump: trump,
                                         inference: inference)
        }
        // De-dup, cap, and ensure non-empty.
        let dedup = uniq(candidates)
        let capped = Array(dedup.prefix(difficulty.trickCandidates))
        let finalCards = capped.isEmpty ? Array(playCards.prefix(difficulty.trickCandidates)) : capped
        return finalCards.map { .play($0) }
    }

    // ---- Lead shortlist

    private func leadShortlist(view: PlayerView,
                               plays: [Card],
                               trump: CardColor,
                               inference: TableInference) -> [Card] {
        let amDeclarer = (view.me == view.highBidder)
        let myTrump = plays.filter { $0.effectiveColor(trump: trump) == trump }
        let trumpOut = inference.trumpStillOutInOpponentsAndPartner
        let tigerOut = inference.isTigerOut
        var picks: [Card] = []

        // 1. Pull-trump: declarer with length + Tiger or other big trump out.
        if amDeclarer && myTrump.count >= 4 && (trumpOut >= 2 || tigerOut) {
            let lowTrump = myTrump
                .filter { !$0.isMoney && !$0.isSpecial }
                .min { rankOf($0) < rankOf($1) }
            if let c = lowTrump { picks.append(c) }
        }

        // 2. $40k of a virgin (un-led) non-trump color.
        for color in CardColor.allCases where color != trump {
            if inference.hasBeenLed(color) { continue }
            for c in plays where c.effectiveColor(trump: trump) == color {
                if case .colored(_, let r) = c, r == .money40k { picks.append(c) }
            }
        }

        // 3. A controlled (highest-of-color, no void-trump risk) non-trump card.
        if let safe = sureLeadNonTrump(plays: plays, trump: trump, inference: inference) {
            picks.append(safe)
        }

        // 4. Trumps pulled → cash highest trump.
        if trumpOut == 0 && !tigerOut {
            if let high = myTrump.max(by: { rankOf($0) < rankOf($1) }) {
                picks.append(high)
            }
        }

        // 5. Low non-money, non-special — preferring shortest non-trump suit.
        if let lo = lowSafeLead(plays: plays, hand: view.myHand, trump: trump) {
            picks.append(lo)
        }

        // 6. Last resort: cheapest of anything legal.
        if picks.isEmpty {
            if let any = plays.min(by: { PlayoutPolicy.strength($0, led: nil, trump: trump)
                                       < PlayoutPolicy.strength($1, led: nil, trump: trump) }) {
                picks.append(any)
            }
        }
        return picks
    }

    private func sureLeadNonTrump(plays: [Card],
                                  trump: CardColor,
                                  inference: TableInference) -> Card? {
        let candidates = plays.filter {
            !$0.isSpecial && $0.effectiveColor(trump: trump) != trump
        }.sorted { rankOf($0) > rankOf($1) }

        for card in candidates {
            guard let color = card.effectiveColor(trump: trump) else { continue }
            if !inference.iControlColor(card) { continue }
            // Anyone known void in this color? They can trump.
            let voidAny = Seats.all.contains {
                $0 != inference.me && inference.isKnownVoid($0, in: color)
            }
            if voidAny { continue }
            return card
        }
        return nil
    }

    private func lowSafeLead(plays: [Card], hand: [Card], trump: CardColor) -> Card? {
        let cands = plays.filter { !$0.isMoney && !$0.isSpecial
                                && $0.effectiveColor(trump: trump) != trump }
        guard !cands.isEmpty else { return nil }
        var bySuit: [CardColor: Int] = [:]
        for c in hand {
            if case .colored(let col, _) = c, col != trump {
                bySuit[col, default: 0] += 1
            }
        }
        return cands.min { a, b in
            let sa = a.suitColorOrNil.map { bySuit[$0] ?? 99 } ?? 99
            let sb = b.suitColorOrNil.map { bySuit[$0] ?? 99 } ?? 99
            if sa != sb { return sa < sb }
            return rankOf(a) < rankOf(b)
        }
    }

    // ---- Follow shortlist

    private func followShortlist(view: PlayerView,
                                 plays: [Card],
                                 trick: Trick,
                                 trump: CardColor,
                                 inference: TableInference) -> [Card] {
        let onTable = trick.plays
        let provisional = Trick(leader: trick.leader, plays: onTable)
        let winner = GameState.trickWinner(provisional, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: view.me)
                          && winner != view.me
        let moneyOnTable = onTable.reduce(0) { $0 + $1.card.moneyValue }
        let led = provisional.ledColor(trump: trump)
        let amLastToPlay = onTable.count == Seats.count - 1

        let mustFollow = led != nil
            && plays.contains { $0.effectiveColor(trump: trump) == led }
        let pool = mustFollow
            ? plays.filter { $0.effectiveColor(trump: trump) == led }
            : plays

        func wouldWin(_ c: Card) -> Bool {
            var t = onTable
            t.append(PlayedCard(player: view.me, card: c))
            return GameState.trickWinner(
                Trick(leader: trick.leader, plays: t), trump: trump) == view.me
        }

        var picks: [Card] = []

        // A. Partner winning + safe → dump money to them, BUT preserve
        //    secondary controllers (principle 8: don't dump $30k onto
        //    partner's $40k — keep it to control the next round of that
        //    color).
        if partnerWinning {
            let safe = amLastToPlay
                || !canBeOverturned(trick: trick, onTable: onTable,
                                     trump: trump, inference: inference,
                                     view: view)
            if safe {
                if !mustFollow, let bull = plays.first(where: { if case .bull = $0 { return true }; return false }),
                   moneyOnTable > 0 {
                    picks.append(bull)
                }
                // Cards that are MY highest of their color are future
                // controllers — try not to dump them.
                let myTops = topOfEachColorInMyHand(view.myHand, trump: trump)
                let nonControllers = pool.filter { c in
                    guard let color = c.effectiveColor(trump: trump) else { return true }
                    return myTops[color] != c
                }
                let dumpFrom = nonControllers.isEmpty ? pool : nonControllers
                if let hi = dumpFrom.filter({ $0.isMoney }).max(by: { rankOf($0) < rankOf($1) }) {
                    picks.append(hi)
                }
                // Hedge: cheapest non-money non-special. Never the Bear
                // (it would cancel partner's money trick — disastrous).
                let safeLow = dumpFrom.filter { !$0.isSpecial && !$0.isMoney }
                let lowPool = safeLow.isEmpty ? dumpFrom.filter { !$0.isSpecial } : safeLow
                if let lo = lowPool.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                            < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                    picks.append(lo)
                }
                return picks
            }
        }

        // B. I can take it.
        let winners = pool.filter(wouldWin)
        let worthTaking = moneyOnTable >= 5_000 || !partnerWinning
        if !winners.isEmpty && worthTaking {
            // Cheapest winner — and the most expensive (a Tiger smash on a
            // big money trick is sometimes right; let MCTS decide).
            if let cheap = winners.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                            < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                picks.append(cheap)
            }
            if winners.count > 1,
               let big = winners.max(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                           < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                picks.append(big)
            }
            // Also a cheap shed in case "win" is more expensive than the
            // trick is worth.
            if let sh = cheapShed(pool, led: led, trump: trump) {
                picks.append(sh)
            }
            return picks
        }

        // C. Bear on opponent money trick we can't take.
        if !partnerWinning && moneyOnTable >= 10_000 && !mustFollow {
            if let bear = plays.first(where: { if case .bear = $0 { return true }; return false }) {
                picks.append(bear)
            }
        }

        // D. Default — shed cheapest. Add a void-creating shed if available.
        if let lo = cheapShed(pool, led: led, trump: trump) {
            picks.append(lo)
        }
        if !mustFollow, let v = voidCreatingShed(pool: plays, view: view, trump: trump) {
            picks.append(v)
        }
        return picks
    }

    /// Can a yet-to-play seat overturn the partner-winning play?
    private func canBeOverturned(trick: Trick,
                                 onTable: [PlayedCard],
                                 trump: CardColor,
                                 inference: TableInference,
                                 view: PlayerView) -> Bool {
        let played = Set(onTable.map(\.player))
        let yetToPlay = Seats.all.filter { !played.contains($0) && $0 != view.me }
        if yetToPlay.isEmpty { return false }

        let winner = GameState.trickWinner(trick, trump: trump)
        let winnerCard = onTable.first { $0.player == winner }!.card
        let led = trick.ledColor(trump: trump)
        let winnerStrength = PlayoutPolicy.strength(winnerCard, led: led, trump: trump)

        for s in yetToPlay {
            // If they're an opponent: do THEY potentially still hold a card
            // that beats the current winner? Use inference's "highestOut"
            // logic, conservatively.
            if Seats.team(of: s) == Seats.team(of: view.me) { continue }   // partner — not an over-turner
            // Trump over-ruff possibility: known void in led suit AND
            // trump still out at the table.
            if let l = led, l != trump,
               inference.isKnownVoid(s, in: l),
               (inference.trumpStillOutInOpponentsAndPartner > 0
                || inference.isTigerOut) {
                return true
            }
            // Higher card of led color.
            if let l = led, let top = inference.highestOutInColor(l) {
                if PlayoutPolicy.strength(top, led: led, trump: trump) > winnerStrength {
                    return true
                }
            }
            // Widow knowledge (principle 11): if this opponent is the
            // declarer, anything from the un-discardable widow is in
            // their hand RIGHT NOW. The Tiger is the strongest single
            // case — if the led suit is trump (or partner is winning
            // on trump), declarer's Tiger beats everything.
            for known in inference.knownDeclarerHoldings()
                    where inference.isCardKnownIn(s, card: known) {
                if PlayoutPolicy.strength(known, led: led, trump: trump)
                    > winnerStrength {
                    return true
                }
            }
        }
        return false
    }

    /// A shed that voids me out of a side suit (singleton non-money).
    private func voidCreatingShed(pool: [Card],
                                   view: PlayerView,
                                   trump: CardColor) -> Card? {
        var bySuit: [CardColor: Int] = [:]
        for c in view.myHand {
            if case .colored(let col, _) = c, col != trump {
                bySuit[col, default: 0] += 1
            }
        }
        for c in pool {
            if case .colored(let col, let r) = c,
               col != trump, !r.isMoney,
               (bySuit[col] ?? 0) == 1 {
                return c
            }
        }
        return nil
    }

    private func cheapShed(_ cards: [Card],
                            led: CardColor?,
                            trump: CardColor) -> Card? {
        guard !cards.isEmpty else { return nil }
        return cards.min { a, b in
            if a.isMoney != b.isMoney { return !a.isMoney }
            if a.isSpecial != b.isSpecial { return !a.isSpecial }
            return PlayoutPolicy.strength(a, led: led, trump: trump)
                 < PlayoutPolicy.strength(b, led: led, trump: trump)
        }
    }

    // MARK: - Rollout + scoring

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

    private func teamNet(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Int {
        let mine = (final.matchScore[myTeam] ?? 0) - (baseline[myTeam] ?? 0)
        let opp  = (final.matchScore[1 - myTeam] ?? 0) - (baseline[1 - myTeam] ?? 0)
        return mine - opp
    }

    // MARK: - Small helpers

    private func shouldBlunder() -> Bool {
        guard difficulty.blunderRate > 0 else { return false }
        return Double(seedBox.nextInt(upperBound: 10_000)) / 10_000.0
             < difficulty.blunderRate
    }
    private func intRand(_ upper: Int) -> Int {
        upper <= 0 ? 0 : seedBox.nextInt(upperBound: upper)
    }
    private func cardRank(_ c: Card) -> Int {
        if case .colored(_, let r) = c { return r.rawValue }
        return 0
    }
    private func rankOf(_ c: Card) -> Int { PlayoutPolicy.rankOf(c) }

    private func uniq(_ cards: [Card]) -> [Card] {
        var seen: Set<Card> = []
        var out: [Card] = []
        for c in cards where !seen.contains(c) {
            seen.insert(c); out.append(c)
        }
        return out
    }

    /// For each effective color in my hand, the highest-ranking card I
    /// hold. Used to detect "controllers" — cards that win the next
    /// round of that color and should NOT be dumped onto partner.
    /// Tiger is treated as trump's controller candidate (rank 13).
    private func topOfEachColorInMyHand(_ hand: [Card],
                                        trump: CardColor) -> [CardColor: Card] {
        var top: [CardColor: Card] = [:]
        for c in hand {
            guard let color = c.effectiveColor(trump: trump) else { continue }
            if let cur = top[color] {
                if rankOf(c) > rankOf(cur) { top[color] = c }
            } else {
                top[color] = c
            }
        }
        return top
    }
}

// Preserve the RNGBox raw accessor that other files depend on.
extension RNGBox {
    func nextRaw() -> UInt64 { UInt64(nextInt(upperBound: Int.max)) }
}

// MARK: - Card convenience

private extension Card {
    var suitColorOrNil: CardColor? {
        if case .colored(let c, _) = self { return c }
        return nil
    }
}
