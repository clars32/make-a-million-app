//
//  MonteCarloAgent+Traditional.swift
//  Make-a-Million
//
//  The TRADITIONAL decision stack: the legible, capability-laddered agent.
//  Every move it plays has a nameable principled reason; strength rises by
//  adding principles, deepening table-reading, and planning ahead at forks —
//  never by random error. See `ai_rewrite.md` §2 for the model.
//
//  Selection order (§2.4):
//    1. Principle decides — most positions collapse to one decisive candidate.
//    2. Genuine fork — ≥2 candidates carry different, each-valid principles;
//       resolved by a bounded search confined to that set (when plansAhead),
//       else by deterministic shortlist priority.
//    3. True tie — lightly randomized over the residual that no principle can
//       separate, drawn from the agent's seedBox so replays stay reproducible.
//
//  This stack is reached only when `difficulty.style == .traditional`
//  (the novice/casual/skilled/expert ladder). The `.adaptive` side-door keeps
//  using the search stack in MonteCarloAgent+TrickPlay / +Bidding unchanged.
//

import Foundation

extension MonteCarloAgent {

    // MARK: - Principled roles (legibility)

    /// A named principled reason a candidate card is on the table. The role is
    /// what makes a move legible (it names WHY) and is how forks (≥2 DIFFERENT
    /// roles compete) are told apart from true ties (one role, interchangeable
    /// cards). Case order is not priority — the builder appends candidates in
    /// the correct contextual priority order so the no-look-ahead tiers resolve
    /// forks deterministically by taking the first.
    nonisolated enum PlayRole: String, Sendable {
        // leads
        case pullTrumpLow, pullTrumpCommanding, leadVirgin40k, sureLeadNonTrump,
             establishDuck, cashHighTrump, lowSafeLead, lastResort
        // follows
        case dumpToPartner, bullDoublePartner, partnerHedge,
             bankMoney, cheapWin, bigWin, bullEscape,
             bearEnemy, voidShed, cheapShed
    }

    /// A legal card paired with the principle it serves.
    nonisolated struct PlayCandidate: Sendable {
        let card: Card
        let role: PlayRole
    }

    /// The result of a Traditional trick decision, exposed (internal) so the
    /// legibility test can assert the chosen card is always a member of the
    /// principled candidate set.
    nonisolated struct TraditionalOutcome: Sendable {
        let move: Move
        /// Every card the principles put forward this decision.
        let candidates: [PlayCandidate]
        /// The role of the chosen card.
        let role: PlayRole
        /// How the choice was made: decisive / fork-search / fork-priority / tie.
        let resolution: String
    }

    // MARK: - Trick play entry point

    func decideTrickPlayTraditional(_ view: PlayerView, legal: [Move]) -> Move {
        let inference = TableInference(view: view,
                                       inference: difficulty.capabilities.inference)
        let outcome = traditionalPlay(view: view, legal: legal, inference: inference)

        if AIDecisionTrace.shared.isEnabled, let card = outcome.move.playedCard {
            let cands = outcome.candidates.map { "\(HandLog.token($0.card)):\($0.role.rawValue)" }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: card, blundered: false,
                candidates: [],
                notes: ["traditional[\(difficulty.capabilities.principles)/"
                        + "\(difficulty.capabilities.inference)] "
                        + "\(outcome.resolution) → \(outcome.role.rawValue)",
                        "principled candidates: " + cands.joined(separator: " ")]))
        }
        return outcome.move
    }

    /// The testable core: build the principled candidate set and apply the
    /// three-layer selection order. Never returns a move outside the candidate
    /// set (legibility is structural).
    func traditionalPlay(view: PlayerView, legal: [Move],
                         inference: TableInference) -> TraditionalOutcome {
        let candidates = traditionalCandidates(view: view, legal: legal,
                                               inference: inference)
        let ctx = keyContext(view: view, inference: inference)

        // Distinct cards in priority order; a card keeps the role it was first
        // tagged with (the highest-priority principle it serves).
        var roleOf: [Card: PlayRole] = [:]
        var distinct: [Card] = []
        for c in candidates where roleOf[c.card] == nil {
            roleOf[c.card] = c.role
            distinct.append(c.card)
        }
        // Defensive fallback: the builder always yields ≥1 candidate, but never
        // play an illegal move if it somehow didn't.
        guard !distinct.isEmpty else {
            return .init(move: legal[0], candidates: candidates,
                         role: .cheapShed, resolution: "fallback")
        }

        // Layer 1 — one decisive candidate.
        if distinct.count == 1 {
            return outcome(distinct[0], roleOf, candidates, "decisive")
        }

        // Distinct PRINCIPLES among the distinct cards.
        let roles = orderedUnique(distinct.map { roleOf[$0]! })

        if roles.count <= 1 {
            // Layer 3 — one principle, interchangeable cards: a true tie.
            let pick = chooseAmongPrincipled(distinct, ctx: ctx)
            return outcome(pick, roleOf, candidates, "true-tie")
        }

        // Layer 2 — a genuine fork between different valid principles.
        if difficulty.capabilities.plansAhead {
            let pick = resolveForkBySearch(view: view, cards: distinct)
            return outcome(pick, roleOf, candidates, "fork:search")
        }
        // No look-ahead: deterministic shortlist priority — the first principle
        // wins, and its co-principled cards (if any) break by the principled key.
        let firstRole = roleOf[distinct[0]]!
        let firstGroup = distinct.filter { roleOf[$0] == firstRole }
        let pick = chooseAmongPrincipled(firstGroup, ctx: ctx)
        return outcome(pick, roleOf, candidates, "fork:priority")
    }

    private func outcome(_ card: Card, _ roleOf: [Card: PlayRole],
                         _ candidates: [PlayCandidate],
                         _ resolution: String) -> TraditionalOutcome {
        .init(move: .play(card), candidates: candidates,
              role: roleOf[card] ?? .cheapShed, resolution: resolution)
    }

    // MARK: - Candidate builder (principle-gated, role-tagged)

    func traditionalCandidates(view: PlayerView, legal: [Move],
                               inference: TableInference) -> [PlayCandidate] {
        let playCards = legal.compactMap { $0.playedCard }
        guard !playCards.isEmpty, let trump = view.trump else {
            return legal.compactMap { $0.playedCard }.map { .init(card: $0, role: .lastResort) }
        }
        let trick = view.currentTrick
        let onTable = trick?.plays ?? []
        if onTable.isEmpty {
            return traditionalLead(view: view, plays: playCards,
                                   trump: trump, inference: inference)
        }
        return traditionalFollow(view: view, plays: playCards, trick: trick!,
                                 trump: trump, inference: inference)
    }

    // ---- Lead

    private func traditionalLead(view: PlayerView, plays: [Card], trump: CardColor,
                                 inference: TableInference) -> [PlayCandidate] {
        let cap = difficulty.capabilities.principles
        let amDeclarer = (view.me == view.highBidder)
        let myTrump = plays.filter { $0.effectiveColor(trump: trump) == trump }
        let trumpOut = inference.trumpStillOutInOpponentsAndPartner
        let tigerOut = inference.isTigerOut
        var out: [PlayCandidate] = []

        // POSITIONAL — pull trump as declarer with length + big trump loose.
        if cap >= .positional && amDeclarer && myTrump.count >= 4
            && (trumpOut >= 2 || tigerOut) {
            if let low = myTrump.filter({ !$0.isMoney && !$0.isSpecial })
                .min(by: { rankOf($0) < rankOf($1) }) {
                out.append(.init(card: low, role: .pullTrumpLow))
            }
            let commanding = myTrump.filter { inference.iControlColor($0) }
                .sorted { rankOf($0) > rankOf($1) }
            if let topNonSpecial = commanding.first(where: { !$0.isSpecial }) {
                out.append(.init(card: topNonSpecial, role: .pullTrumpCommanding))
            } else if let boss = commanding.first {
                out.append(.init(card: boss, role: .pullTrumpCommanding))
            }
        }

        // POSITIONAL — $40k of a virgin (un-led) non-trump color.
        if cap >= .positional {
            for color in CardColor.allCases where color != trump {
                if inference.hasBeenLed(color) { continue }
                for c in plays where c.effectiveColor(trump: trump) == color {
                    if case .colored(_, let r) = c, r == .money40k {
                        out.append(.init(card: c, role: .leadVirgin40k))
                    }
                }
            }
        }

        // COMPLETE — establishment duck: with length behind a virgin side boss,
        // duck low first and cash the boss later (a fork against cashing it now).
        if cap >= .complete, let duck = establishDuckLead(plays: plays, trump: trump,
                                                          inference: inference) {
            out.append(.init(card: duck, role: .establishDuck))
        }

        // POSITIONAL — a controlled, no-void-risk top of a side suit (cash a sure
        // winner).
        if cap >= .positional,
           let safe = sureLeadNonTrump(plays: plays, trump: trump, inference: inference) {
            out.append(.init(card: safe, role: .sureLeadNonTrump))
        }

        // POSITIONAL — trumps pulled → cash highest trump.
        if cap >= .positional && trumpOut == 0 && !tigerOut {
            if let high = myTrump.max(by: { rankOf($0) < rankOf($1) }) {
                out.append(.init(card: high, role: .cashHighTrump))
            }
        }

        // CORE — low safe lead (prefers the shortest non-trump suit). The base
        // skill every tier has.
        if let lo = lowSafeLead(plays: plays, hand: view.myHand, trump: trump) {
            out.append(.init(card: lo, role: .lowSafeLead))
        }

        // CORE — last resort: the cheapest legal card.
        if out.isEmpty,
           let any = plays.min(by: { PlayoutPolicy.strength($0, led: nil, trump: trump)
                                   < PlayoutPolicy.strength($1, led: nil, trump: trump) }) {
            out.append(.init(card: any, role: .lastResort))
        }
        return out
    }

    /// With ≥3 cards behind a still-controlled, un-led side boss, the low card
    /// of that suit (duck now, cash the boss once the suit is forced).
    private func establishDuckLead(plays: [Card], trump: CardColor,
                                   inference: TableInference) -> Card? {
        for color in CardColor.allCases where color != trump {
            if inference.hasBeenLed(color) { continue }
            let mine = plays.filter { $0.effectiveColor(trump: trump) == color }
            guard mine.count >= 3 else { continue }
            guard let top = mine.max(by: { rankOf($0) < rankOf($1) }),
                  inference.iControlColor(top) else { continue }
            if let low = mine.filter({ !$0.isMoney && !$0.isSpecial })
                .min(by: { rankOf($0) < rankOf($1) }) {
                return low
            }
        }
        return nil
    }

    // ---- Follow

    private func traditionalFollow(view: PlayerView, plays: [Card], trick: Trick,
                                   trump: CardColor,
                                   inference: TableInference) -> [PlayCandidate] {
        let cap = difficulty.capabilities.principles
        let onTable = trick.plays
        let provisional = Trick(leader: trick.leader, plays: onTable)
        let winner = GameState.trickWinner(provisional, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: view.me)
                          && winner != view.me
        let moneyOnTable = onTable.reduce(0) { $0 + $1.card.moneyValue }
        let effValue = PlayoutPolicy.tableValue(onTable)
        let beared = PlayoutPolicy.tableIsBeared(onTable)
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
        let ctx = keyContext(view: view, inference: inference)
        var out: [PlayCandidate] = []

        // A. Partner winning + safe → dump money to them. "Safe" degrades with
        //    the tier's inference: a Novice (no counting) can't see threats and
        //    so dumps even when it would be over-ruffed — a believable mistake.
        if partnerWinning {
            let safe = amLastToPlay
                || !canBeOverturned(trick: trick, onTable: onTable,
                                    trump: trump, inference: inference, view: view)
            if safe {
                // COMPLETE — a Bull doubles a partner-winning money trick (and is
                // a free exit for a Bull that would otherwise be forced onto the
                // final trick).
                if cap >= .complete, !mustFollow,
                   let bull = plays.first(where: { $0.isBull }) {
                    out.append(.init(card: bull, role: .bullDoublePartner))
                }
                // COMPLETE — if a loose Bear can still land here, or the trick is
                // already Beared, money is wasted: offer only the safe low shed.
                let bearThreat = cap >= .complete && !amLastToPlay
                    && inference.opponentCanBearTrick(led: led, currentTrick: trick)
                if !beared && !bearThreat {
                    // POSITIONAL — preserve controllers (don't dump my top-of-color
                    // onto partner). Lower tiers dump the highest money outright.
                    let dumpFrom: [Card]
                    if cap >= .positional {
                        let myTops = topOfEachColorInMyHand(view.myHand, trump: trump)
                        let nonControllers = pool.filter { c in
                            guard let color = c.effectiveColor(trump: trump) else { return true }
                            return myTops[color] != c
                        }
                        dumpFrom = nonControllers.isEmpty ? pool : nonControllers
                    } else {
                        dumpFrom = pool
                    }
                    if let hi = dumpFrom.filter({ $0.isMoney })
                        .max(by: { rankOf($0) < rankOf($1) }) {
                        out.append(.init(card: hi, role: .dumpToPartner))
                    }
                }
                // POSITIONAL — a hedge (shed low instead of committing money) the
                // look-ahead tiers weigh against the dump; under a Bear threat at
                // COMPLETE it is the only money-safe option, so offer it then too.
                if cap >= .positional || beared || (cap >= .complete) {
                    let safeLow = pool.filter { !$0.isSpecial && !$0.isMoney }
                    let lowPool = safeLow.isEmpty ? pool.filter { !$0.isSpecial } : safeLow
                    for c in bestKeyGroup(lowPool, ctx: ctx) {
                        out.append(.init(card: c, role: .partnerHedge))
                    }
                }
                if out.isEmpty {   // guarantee a legal exit
                    if let lo = cheapShed(pool, led: led, trump: trump) {
                        out.append(.init(card: lo, role: .partnerHedge))
                    }
                }
                return out
            }
        }

        // B. I can take it (and the trick is worth taking).
        let winners = pool.filter(wouldWin)
        let worthTaking = !beared && (effValue >= 5_000 || !partnerWinning)
        if !winners.isEmpty && worthTaking {
            // COOPERATIVE — when last to play the win is certain, so banking the
            // most money LOCKS it in (primary over a cheap win in this context).
            if cap >= .cooperative, amLastToPlay,
               let bank = winners.filter({ $0.isMoney }).max(by: { $0.moneyValue < $1.moneyValue }) {
                out.append(.init(card: bank, role: .bankMoney))
            }
            // CORE — win as cheaply as possible.
            if let cheap = winners.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                           < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                out.append(.init(card: cheap, role: .cheapWin))
            }
            // POSITIONAL — also the biggest winner (a Tiger-smash is sometimes
            // right): a fork the look-ahead tiers resolve.
            if cap >= .positional, winners.count > 1,
               let big = winners.max(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                          < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                out.append(.init(card: big, role: .bigWin))
            }
            // COMPLETE — Bull escape onto a near-worthless pot rather than hold it
            // into the forced final-trick double.
            if cap >= .complete, !beared, effValue <= 10_000,
               let bull = pool.first(where: { $0.isBull }) {
                out.append(.init(card: bull, role: .bullEscape))
            }
            // POSITIONAL — a cheap shed in case the win costs more than the pot.
            if cap >= .positional, let sh = cheapShed(pool, led: led, trump: trump) {
                out.append(.init(card: sh, role: .cheapShed))
            }
            return out
        }

        // C. Bear an opponent's money trick we can't take. COOPERATIVE+.
        if cap >= .cooperative, !partnerWinning, !mustFollow {
            let bullDoubles = cap >= .complete
                && inference.opponentCanBullTrick(led: led, currentTrick: trick)
            if effValue >= 10_000 || (bullDoubles && moneyOnTable > 0) {
                if let bear = plays.first(where: { $0.isBear }) {
                    out.append(.init(card: bear, role: .bearEnemy))
                }
            }
        }

        // COMPLETE — Bull escape on a small pot we're not winning.
        if cap >= .complete, !partnerWinning, !beared, effValue <= 10_000,
           let bull = pool.first(where: { $0.isBull }) {
            out.append(.init(card: bull, role: .bullEscape))
        }

        // D. Default — shed. The Bull must never be the cheap shed onto an
        //    opponent's money trick (it doubles their take). COMPLETE adds the
        //    void-creating shed as an alternative.
        let bullIsCostly = cap >= .complete && !partnerWinning && moneyOnTable > 0
        let shedEligible = bullIsCostly ? pool.filter { !$0.isBull } : pool
        for c in bestKeyGroup(shedEligible.isEmpty ? pool : shedEligible, ctx: ctx) {
            out.append(.init(card: c, role: .cheapShed))
        }
        if cap >= .complete, !mustFollow,
           let v = voidCreatingShed(pool: plays, view: view, trump: trump) {
            out.append(.init(card: v, role: .voidShed))
        }
        if out.isEmpty, let lo = cheapShed(pool, led: led, trump: trump) {
            out.append(.init(card: lo, role: .cheapShed))
        }
        return out
    }

    // MARK: - Principled key + tie resolution (§2.3)

    /// The context the principled key reads: trump, whether my team is safely
    /// banking this trick (so money should be MAXIMISED, not minimised), and my
    /// per-color controllers (so a future controller isn't burned on a tie).
    struct KeyContext {
        let trump: CardColor
        let bankToOwnTeam: Bool
        let myTops: [CardColor: Card]
    }

    func keyContext(view: PlayerView, inference: TableInference) -> KeyContext {
        let trump = view.trump ?? .red
        let bank: Bool = {
            guard let t = view.trump,
                  let trick = view.currentTrick, !trick.plays.isEmpty else { return false }
            let winner = GameState.trickWinner(trick, trump: t)
            guard Seats.team(of: winner) == Seats.team(of: view.me) else { return false }
            return trick.plays.count == Seats.count - 1
                || !canBeOverturned(trick: trick, onTable: trick.plays,
                                    trump: t, inference: inference, view: view)
        }()
        return KeyContext(trump: trump, bankToOwnTeam: bank,
                          myTops: topOfEachColorInMyHand(view.myHand, trump: trump))
    }

    /// The principled key (§2.3): a human notices these, so they decide
    /// DETERMINISTICALLY. Lower tuple = preferred. Shares its first three terms
    /// with `tiePreference` (`tieKeyPrefix`); the 4th term swaps `tiePreference`'s
    /// rank for controller-ness, so a future controller never loses a tie to a
    /// junk card. Rank is the RESIDUAL that randomization draws over.
    func principledKey(_ c: Card, ctx: KeyContext) -> (Int, Int, Int, Int) {
        let (special, money, isTrump) = Self.tieKeyPrefix(
            c, trump: ctx.trump, bankToOwnTeam: ctx.bankToOwnTeam)
        let isController: Int = {
            guard let color = c.effectiveColor(trump: ctx.trump) else { return 0 }
            return ctx.myTops[color] == c ? 1 : 0
        }()
        return (special, money, isTrump, isController)
    }

    /// The cards sharing the minimum principled key — the genuinely
    /// interchangeable set a true tie randomizes over.
    func bestKeyGroup(_ cards: [Card], ctx: KeyContext) -> [Card] {
        guard !cards.isEmpty else { return [] }
        let keyed = cards.map { ($0, principledKey($0, ctx: ctx)) }
        let best = keyed.map { $0.1 }.min { $0 < $1 }!
        return keyed.filter { $0.1 == best }.map { $0.0 }
    }

    /// Group → best key-group → deterministic single member, else randomize
    /// uniformly over the residual, drawn from the agent's seedBox so
    /// (seed, position) → the same move (§2.3 step 4).
    func chooseAmongPrincipled(_ cards: [Card], ctx: KeyContext) -> Card {
        let group = bestKeyGroup(cards, ctx: ctx)
        guard group.count > 1 else { return group.first ?? cards[0] }
        // Canonical order so the random draw is stable regardless of input order.
        let ordered = group.sorted { rankOf($0) < rankOf($1) }
        return ordered[intRand(ordered.count)]
    }

    // MARK: - Fork resolution by bounded search (§2.4 layer 2)

    /// Bounded PIMC confined to the fork's co-principled candidate set — never
    /// the full legal move set. `capabilities.forkSamples` worlds, the greedy
    /// PlayoutPolicy tail, scored by team net (Traditional uses no match-win
    /// blend / exact endgame). Ties fall back to the principled key.
    func resolveForkBySearch(view: PlayerView, cards: [Card]) -> Card {
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        let worlds = max(1, difficulty.capabilities.forkSamples)
        var totals = [Card: Double]()
        var counts = [Card: Int]()
        for _ in 0..<worlds {
            guard let state = sampledWorldTraditional(view: view) else { continue }
            for c in cards {
                guard let after = try? state.applying(.play(c), by: view.me) else { continue }
                totals[c, default: 0] += evaluateWorld(after, myTeam: myTeam,
                                                       baseline: baseline, exactGate: 0)
                counts[c, default: 0] += 1
            }
        }
        let scored = cards.compactMap { c -> (Card, Double)? in
            guard let n = counts[c], n > 0 else { return nil }
            return (c, totals[c]! / Double(n))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return cards[0] }
        // Exact-EV ties (rare with floats) resolve by the principled key.
        let tied = scored.filter { $0.1 == best.1 }.map { $0.0 }
        if tied.count > 1 {
            let inference = TableInference(view: view,
                                           inference: difficulty.capabilities.inference)
            return chooseAmongPrincipled(tied, ctx: keyContext(view: view, inference: inference))
        }
        return best.0
    }

    /// A determinized world for the Traditional fork search: the same sampler the
    /// Adaptive path uses, with the Traditional profile's auction/widow reads and
    /// none of the research filters.
    private func sampledWorldTraditional(view: PlayerView) -> GameState? {
        var det = Determinizer(view: view, seed: seedBox.nextRaw(),
                               bidLeanStrength: difficulty.bidLeanStrength,
                               deduceWidowHoldings: difficulty.deduceWidowHoldings,
                               declarerTrumpBias: 0,
                               filterDominatedDonation: false,
                               filterBearDecline: false)
        return (det.sample() ?? det.sampleUnconstrained())?.state
    }

    // MARK: - Small utilities

    private func orderedUnique(_ roles: [PlayRole]) -> [PlayRole] {
        var seen: Set<PlayRole> = []
        var out: [PlayRole] = []
        for r in roles where !seen.contains(r) { seen.insert(r); out.append(r) }
        return out
    }

    // MARK: - Traditional bidding (scalar, legible)

    /// Traditional bidding is the existing `decideBid` rules with the scalar
    /// (mean) valuation — the Traditional presets set `rolloutBidEval = false`,
    /// so `decideBid` already bids on `expectedGross` with no rollout, applies
    /// the legible partner-respect / match-aware / minimum-raise rules, and uses
    /// the tier's evaluator tables. The distribution-aware rollout bidder is an
    /// Adaptive-only feature (§4).
    func decideBidTraditional(_ view: PlayerView, legal: [Move]) -> Move {
        decideBid(view, legal: legal)
    }
}
