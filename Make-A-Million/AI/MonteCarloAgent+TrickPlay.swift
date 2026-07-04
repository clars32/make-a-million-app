//
//  MonteCarloAgent+TrickPlay.swift
//  Make-a-Million
//
//  Trick-play decision: heuristic shortlist + MCTS branch selection.
//  Split out of MonteCarloAgent.swift; same type via `extension MonteCarloAgent`.
//

import Foundation

extension MonteCarloAgent {

    // MARK: - Trick play (heuristic shortlist + MCTS)

    func decideTrickPlay(_ view: PlayerView, legal: [Move]) -> Move {
        let inference = TableInference(view: view,
                                       inference: difficulty.inferenceLevel)
        let shortlist = trickShortlist(view: view,
                                       legal: legal,
                                       inference: inference)

        // EXACT-ENDGAME GATE for this decision: rollouts hand off to the
        // solver once the side to act holds ≤ `rolloutExactTricks` cards;
        // when the ROOT decision itself falls inside the `exactEndgameTricks`
        // window the gate rises to my current hand size, so every candidate
        // is solved immediately (no greedy steps at all).
        let exactRootActive = difficulty.exactEndgameTricks > 0
            && view.myHand.count <= difficulty.exactEndgameTricks
        let exactGate = exactRootActive
            ? max(difficulty.research.rolloutExactTricks, view.myHand.count)
            : difficulty.research.rolloutExactTricks

        // Table-read shared by both paths, built only when capturing. The
        // legal-vs-shortlist line is what makes an OMISSION visible — when the
        // strongest move never reaches MCTS because the heuristic gate dropped
        // it, this is the only place that shows up.
        let baseNotes: [String] = AIDecisionTrace.shared.isEnabled
            ? (exactRootActive
               ? ["exact endgame: candidates graded by alpha-beta per world, not rollouts"]
               : [])
              + shortlistNote(legal: legal, shortlist: shortlist)
              + tracePlayNotes(view: view, inference: inference)
            : []

        // Singleton shortlist: the heuristic narrowed ≥2 legal moves to one, so
        // MCTS is skipped. Still a real decision — record it (with no scores)
        // so heuristically-forced plays aren't invisible to review.
        if shortlist.count == 1 {
            if AIDecisionTrace.shared.isEnabled, let card = shortlist[0].playedCard {
                AIDecisionTrace.shared.record(.init(
                    seat: view.me, chosen: card, blundered: false,
                    candidates: [],
                    notes: ["forced by shortlist (no MCTS)"] + baseNotes))
            }
            return shortlist[0]
        }

        // MCTS over determinized worlds: for each candidate, sample
        // worlds, apply candidate, rollout via PlayoutPolicy, score by
        // team net.
        let myTeam = Seats.team(of: view.me)
        let baseline = view.matchScore
        var totals = [Move: Double]()
        var weights = [Move: Double]()
        var counts = [Move: Int]()

        // Per-decision search budget (rollouts). Shared by both estimators so
        // an IS-MCTS A/B isolates the estimator, not the compute.
        let budget = difficulty.samples * max(4, difficulty.trickCandidates)

        // Fresh determinized world with the root player to act — the sampler
        // both estimators draw from (same hard deductions / soft priors).
        func sampledWorld() -> (world: AIWorld, determinizer: Determinizer)? {
            var det = Determinizer(view: view, seed: seedBox.nextRaw(),
                                   bidLeanStrength: difficulty.bidLeanStrength,
                                   deduceWidowHoldings: difficulty.deduceWidowHoldings,
                                   declarerTrumpBias: difficulty.research.declarerTrumpBias,
                                   filterDominatedDonation: difficulty.research.filterDominatedDonation,
                                   filterBearDecline: difficulty.research.filterBearDecline)
            let world = difficulty.research.playConsistencyFilter
                ? det.sampleConsistent()
                : (det.sample() ?? det.sampleUnconstrained())
            guard let world else { return nil }
            return (world, det)
        }

        func sampleWeightedWorld() -> (state: GameState, weight: Double)? {
            guard let sample = sampledWorld() else { return nil }
            let world = sample.world
            var weight = 1.0
            if difficulty.research.playHistoryWeighting > 0 {
                weight *= sample.determinizer.playHistoryWeight(
                    world, strength: difficulty.research.playHistoryWeighting)
            }
            if difficulty.auctionWindowWeighting > 0 {
                weight *= sample.determinizer.auctionWindowWeight(
                    world,
                    strength: difficulty.auctionWindowWeighting,
                    tables: difficulty.evaluatorTables)
            }
            return (world.state, weight)
        }

        func sampleWorldState() -> GameState? {
            sampledWorld()?.world.state
        }

        if difficulty.research.useISMCTS {
            // SINGLE-OBSERVER IS-MCTS: one tree, a fresh determinization per
            // iteration, opponents/partner searched (not assumed greedy-
            // omniscient), PlayoutPolicy finishing past the frontier. Root
            // children map straight onto the same totals/counts the tie-break
            // and trace tail below already consume.
            // Optionally narrow the ROOT to the heuristic shortlist (even under
            // full-width search) so iterations concentrate; the tree still
            // searches all legal replies at deeper nodes.
            let ismctsRoot = difficulty.research.ismctsShortlistRoot
                ? trickShortlist(view: view, legal: legal,
                                 inference: inference, forceNarrow: true)
                : shortlist
            let stats = ISMCTS.search(
                rootCandidates: ismctsRoot,
                rootTeam: myTeam,
                iterations: budget * max(1, difficulty.research.ismctsBudgetMultiplier),
                sampleWorld: sampleWorldState,
                leafValue: { evaluateWorld($0, myTeam: myTeam,
                                           baseline: baseline,
                                           exactGate: max(difficulty.research.rolloutExactTricks,
                                                          difficulty.exactEndgameTricks)) },
                policyMove: { policyMove(in: $0, seat: $0.toAct) },
                nextRandom: { seedBox.nextRaw() })
            for st in stats where st.visits > 0 {
                totals[st.move] = st.total
                counts[st.move] = st.visits
            }
        } else {
            // DEPTH-1 PIMC with ROLLOUT-BUDGET REALLOCATION: every sampled
            // world is reused for every candidate, so a 13-candidate decision
            // spends 13× the rollouts of a 2-candidate one — yet narrow
            // decisions are where variance bites hardest ("R$5 or R$40 under a
            // loose Tiger" hinges on one hidden card, and produced opposite
            // $80k+ preferences on back-to-back identical deals). Hold the
            // rollout budget roughly constant instead: few candidates →
            // proportionally more sampled worlds, capped at 4× base; wide
            // decisions keep the base sample count.
            let worldCount = min(difficulty.samples * 4,
                                 max(difficulty.samples, budget / max(1, shortlist.count)))
            for _ in 0..<worldCount {
                guard let world = sampleWeightedWorld() else { continue }
                for cand in shortlist {
                    guard let afterMine = try? world.state.applying(cand, by: view.me)
                    else { continue }
                    let u = evaluateWorld(afterMine, myTeam: myTeam,
                                          baseline: baseline, exactGate: exactGate)
                    totals[cand, default: 0] += world.weight * u
                    weights[cand, default: 0] += world.weight
                    counts[cand, default: 0] += 1
                }
            }
        }

        let scored = shortlist
            .filter { (weights[$0] ?? Double(counts[$0] ?? 0)) > 0 }
            .map { move -> (Move, Double) in
                let denom = weights[move] ?? Double(counts[move] ?? 1)
                return (move, totals[move]! / denom)
            }
            .sorted { $0.1 > $1.1 }

        guard let topMean = scored.first?.1 else { return shortlist[0] }

        // Near-tie tiebreak: when candidates score within MCTS noise of the
        // best, the dollars printed on the card and the conservation rules
        // decide — those are CERTAIN, a sub-noise difference in rollout means
        // is not. Ordering (see `tiePreference`): never spend specials on a
        // tie, then feed an opponent-bound trick as LITTLE money as possible
        // (or a safely-partner-bound trick as MUCH as possible), then
        // conserve trump, then lowest rank. Full-width search made the money
        // term necessary: dominated money-donations now reach MCTS, and a
        // money-blind tie once donated the G$40 over the G$5 in real play.
        // Is MY TEAM safely taking this trick (I win it, OR a partner does and
        // it can't be overturned)? Then a near-tie should BANK the most money;
        // otherwise (donating to an opponent, or leading into exposure) it
        // commits the least. The old form only counted a partner's win, so the
        // agent under-banked the trick it was taking ITSELF (handlog 8: played
        // Y$30 over Y$40 / Y$15 over Y$30 on its own winners).
        let bankToOwnTeam: Bool = {
            guard let trump = view.trump,
                  let trick = view.currentTrick, !trick.plays.isEmpty
            else { return false }
            let winner = GameState.trickWinner(trick, trump: trump)
            guard Seats.team(of: winner) == Seats.team(of: view.me) else { return false }
            // A provably-void opponent holding the loose Bear doesn't change
            // the WINNER (canBeOverturned can't see it) but zeroes the pot —
            // banking max money into that trick feeds the Bear. Only bites on
            // near-ties (sub-$20k mean gaps); when the threat dominates, the
            // rollout means already separate the candidates. No-op when I am
            // last to play (nobody left to Bear).
            if inference.opponentCanBearTrick(led: trick.ledColor(trump: trump),
                                              currentTrick: trick) { return false }
            return trick.plays.count == Seats.count - 1
                || !canBeOverturned(trick: trick, onTable: trick.plays,
                                    trump: trump, inference: inference,
                                    view: view)
        }()
        // TIE WINDOW: candidates within this much mean-net of the best are
        // "ties," decided by the certain dollars (`tiePreference`) rather than
        // a sub-noise difference in rollout means. A flat $20k is deliberate and
        // WELL-CALIBRATED: a NOISE-SCALED window (size it to the paired standard
        // error, trusting the search more when it's confident) was built and
        // A/B'd (handlog 8 T6 motivation) and read NEUTRAL-to-−5pp vs this flat
        // value (100 / baseSeed 1: 53% flat → 48% noise-scaled) — sub-$20k mean
        // gaps really are mostly noise, and the conservation tiebreak beats them.
        // So the flat window stays; see `tiePreference` for the (separate, kept)
        // money-direction fix.
        let tieEps = 20_000.0
        let best = scored
            .filter { $0.1 >= topMean - tieEps }
            .min {
                guard let trump = view.trump,
                      let a = $0.0.playedCard, let b = $1.0.playedCard
                else { return false }
                return Self.tiePreference(a, trump: trump, bankToOwnTeam: bankToOwnTeam)
                     < Self.tiePreference(b, trump: trump, bankToOwnTeam: bankToOwnTeam)
            }
            ?? scored[0]

        var blundered = false
        var chosen = best.0
        if shouldBlunder(), scored.count > 1 {
            // Believable AND bounded: blunder only among non-best moves that cost
            // no more than `blunderMaxRegret` vs the best, so an "easy" mistake is
            // a slightly-wrong card, never a catastrophic giveaway (e.g. feeding
            // the $40k). Picking the strictly worst card was the old behaviour.
            let blunderMaxRegret = 60_000.0   // TUNE
            let candidates = scored.filter {
                $0.0 != best.0 && topMean - $0.1 <= blunderMaxRegret
            }
            if !candidates.isEmpty {
                chosen = candidates[intRand(candidates.count)].0
                blundered = true
            }
        }

        // Debug capture (off in normal play and self-play): record the scored
        // shortlist and the table-read that picked the branch, so a reviewer
        // can see WHY this move beat the alternatives.
        if AIDecisionTrace.shared.isEnabled, let card = chosen.playedCard {
            let cands = scored.compactMap { mv, mean -> AIDecisionTrace.Candidate? in
                guard let c = mv.playedCard else { return nil }
                return .init(card: c, meanNet: mean, samples: counts[mv] ?? 0)
            }
            AIDecisionTrace.shared.record(.init(
                seat: view.me, chosen: card, blundered: blundered,
                candidates: cands,
                notes: baseNotes))
        }

        return chosen
    }

    /// One trace line showing the full legal play set and what survived the
    /// heuristic shortlist gate. Makes omission failures (the right move never
    /// reaching MCTS) legible. Built only when capture is on.
    func shortlistNote(legal: [Move], shortlist: [Move]) -> [String] {
        let legalCards = legal.compactMap { $0.playedCard }
        let shortCards = shortlist.compactMap { $0.playedCard }
        guard !legalCards.isEmpty else { return [] }
        return ["legal \(legalCards.count): \(legalCards.map(HandLog.token).joined(separator: " "))"
                + "  →  shortlisted \(shortCards.count): "
                + shortCards.map(HandLog.token).joined(separator: " ")]
    }

    /// A compact, human-readable table-read for the decision trace. Mirrors
    /// the signals the shortlist branches actually key on — partner control,
    /// whether the partner-dump was treated as contestable (the exact flag
    /// behind "should I overtake my own partner?"), loose specials, and the
    /// highest card still out in the relevant colors. Built only when the
    /// trace is enabled.
    func tracePlayNotes(view: PlayerView,
                                inference: TableInference) -> [String] {
        guard let trump = view.trump else { return [] }
        var n: [String] = []
        n.append("tigerOut=\(inference.isTigerOut)"
                 + " trumpOut=\(inference.trumpStillOutInOpponentsAndPartner)"
                 + " bullOut=\(inference.isBullOut) bearOut=\(inference.isBearOut)")

        guard let trick = view.currentTrick, !trick.plays.isEmpty else {
            n.append("leading; amDeclarer=\(view.me == view.highBidder)")
            if let hi = inference.highestOutInColor(trump) {
                n.append("highest trump still out: \(HandLog.token(hi))")
            }
            return n
        }

        let led = trick.ledColor(trump: trump)
        let winner = GameState.trickWinner(trick, trump: trump)
        let partnerWinning = Seats.team(of: winner) == Seats.team(of: view.me)
                          && winner != view.me
        n.append("following  led=\(led.map(HandLog.colorInitial) ?? "—")"
                 + "  currentWinner=\(HandLog.short(winner))"
                 + "  partnerWinning=\(partnerWinning)")

        if partnerWinning {
            // The crux flag: when the partner-dump is judged unsafe the agent
            // drops into the "take it myself" branch, which is what makes it
            // overtake its own partner (and can surface a Tiger smash).
            let overturnable = canBeOverturned(
                trick: trick, onTable: trick.plays,
                trump: trump, inference: inference, view: view)
            n.append(overturnable
                ? "partner-dump UNSAFE — trick judged still overturnable, "
                  + "so 'take it myself' candidates are in play"
                : "partner-dump SAFE — partner's win is uncontested")
        }
        if let l = led, let hi = inference.highestOutInColor(l) {
            n.append("highest \(HandLog.colorName(l)) still out (at someone else): \(HandLog.token(hi))")
        }
        let held = inference.knownDeclarerHoldings()
        if !held.isEmpty {
            n.append("declarer must still hold (from widow): "
                     + held.map(HandLog.token).sorted().joined(separator: " "))
        }
        return n
    }

    /// Build the candidate list MCTS evaluates. This is where the human
    /// principles live: we trim from the full legal set down to "moves a
    /// strong player would seriously consider".
    /// Internal (not private) so the specials-rescue invariant below is
    /// directly testable without MCTS in the loop.
    /// `forceNarrow` runs the heuristic narrowing even when the profile's
    /// `searchAllLegalMoves` is on — used to give the IS-MCTS ROOT a small
    /// candidate set (so iterations concentrate) while the tree still searches
    /// all legal replies deeper. The PIMC path and the trace use the normal
    /// (full-width-respecting) call.
    func trickShortlist(view: PlayerView,
                        legal: [Move],
                        inference: TableInference,
                        forceNarrow: Bool = false) -> [Move] {
        // FULL-WIDTH SEARCH (A/B lever): no gate at all — MCTS grades every
        // legal move. Omission failures become structurally impossible.
        if difficulty.searchAllLegalMoves && !forceNarrow { return legal }

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
        var finalCards = capped.isEmpty ? Array(playCards.prefix(difficulty.trickCandidates)) : capped
        // SPECIALS RESCUE: never let a legal Bull/Bear be silently dropped by
        // a singleton shortlist. A singleton skips MCTS entirely, so a one-
        // line shed comparator ends up deciding six-figure special sequencing
        // on its own (it has kept the Bull and spent the Bear — backwards —
        // letting the final trick get doubled against us). Appending the
        // dropped special forces the search to arbitrate.
        if finalCards.count == 1 {
            for c in playCards where (c.isBull || c.isBear) && !finalCards.contains(c) {
                finalCards.append(c)
            }
        }
        return finalCards.map { .play($0) }
    }

    // ---- Lead shortlist

    func leadShortlist(view: PlayerView,
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

            // Lead-high-to-pull: leading the LOWEST trump donates the round to
            // any higher trump an opponent still holds (and any money they bank
            // on it). When I hold the boss trump I can instead pull from the
            // top — the round still WINS and I keep the lead. Offer the highest
            // NON-special trump that commands the suit (keeping the Tiger in
            // reserve to ruff); fall back to a commanding special (the Tiger)
            // only when nothing else controls. MCTS then weighs high vs low.
            let commanding = myTrump
                .filter { inference.iControlColor($0) }
                .sorted { rankOf($0) > rankOf($1) }
            if let topNonSpecial = commanding.first(where: { !$0.isSpecial }) {
                picks.append(topNonSpecial)
            } else if let boss = commanding.first {
                picks.append(boss)
            }
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

        // 4b. Forced-surrender alternatives (only when no productive lead exists):
        // keep the lead by cashing a commanding trump, or a defender force-ruff
        // into a low-money opponent void — so MCTS weighs them against the junk
        // exit instead of only surrendering (Hand-1-t7).
        if picks.isEmpty {
            if let keep = keepLeadTrumpLead(plays: plays, trump: trump,
                                            inference: inference) {
                picks.append(keep)
            }
            if !amDeclarer,
               let force = forceRuffLead(plays: plays, trump: trump,
                                         inference: inference) {
                picks.append(force)
            }
        }

        // 5. Junk exit. Money-aware (avoid ruffable / live-money colors) when
        // the inference can read it; the naive shortest-suit lowSafeLead is the
        // fallback. (Full-width tiers grade every legal lead anyway; this sharpens
        // the curated shortlist for the rest.)
        if let exit = safeExitLead(plays: plays, hand: view.myHand,
                                   trump: trump, inference: inference) {
            picks.append(exit)
        } else if let lo = lowSafeLead(plays: plays, hand: view.myHand, trump: trump) {
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

    func sureLeadNonTrump(plays: [Card],
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

    func lowSafeLead(plays: [Card], hand: [Card], trump: CardColor) -> Card? {
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

    /// Money-aware safe exit — the smarter junk lead for table-reading tiers.
    /// Same candidate pool as `lowSafeLead` (low, non-money, non-special,
    /// non-trump) but it chooses the exit COLOR to bleed the least to the
    /// opponents instead of merely taking the shortest suit. Ordering, safest
    /// first: (1) avoid a color an opponent can RUFF (known void + trump still
    /// out) — leading there hands them a ruff and any money that falls; (2) the
    /// least live bankable money in the color (a money-DEAD color can't gift
    /// anything); only THEN (3) the shortest suit (toward a void, as before) and
    /// (4) the lowest rank. Needs counting inference for the money/void reads;
    /// the lower tiers keep the naive `lowSafeLead`.
    func safeExitLead(plays: [Card], hand: [Card], trump: CardColor,
                      inference: TableInference) -> Card? {
        let cands = plays.filter { !$0.isMoney && !$0.isSpecial
                                && $0.effectiveColor(trump: trump) != trump }
        guard !cands.isEmpty else { return nil }
        var bySuit: [CardColor: Int] = [:]
        for c in hand {
            if case .colored(let col, _) = c, col != trump { bySuit[col, default: 0] += 1 }
        }
        let myTeam = Seats.team(of: inference.me)
        var riskCache: [CardColor: (ruff: Int, money: Int)] = [:]
        func risk(_ color: CardColor) -> (ruff: Int, money: Int) {
            if let r = riskCache[color] { return r }
            let ruff = Seats.all.contains {
                $0 != inference.me && Seats.team(of: $0) != myTeam
                    && inference.isKnownVoid($0, in: color)
            } ? 1 : 0
            let r = (ruff: ruff, money: inference.outstandingMoney(in: color))
            riskCache[color] = r
            return r
        }
        return cands.min { a, b in
            let ca = a.suitColorOrNil ?? trump
            let cb = b.suitColorOrNil ?? trump
            let ra = risk(ca), rb = risk(cb)
            if ra.ruff != rb.ruff { return ra.ruff < rb.ruff }     // avoid ruffable colors
            if ra.money != rb.money { return ra.money < rb.money }  // less live money
            let la = bySuit[ca] ?? 99, lb = bySuit[cb] ?? 99
            if la != lb { return la < lb }                          // shorter suit (toward void)
            return rankOf(a) < rankOf(b)                            // lowest rank
        }
    }

    /// When forced to surrender the lead, a trump I hold that COMMANDS the trick
    /// right now (the Tiger, or a boss trump no loose trump beats) — leading it
    /// wins a guaranteed trick and KEEPS the lead instead of feeding an
    /// opponent's ruff (Hand-1-t7: holding the Tiger but donating a low card into
    /// a $70k ruff). Prefers the lowest non-special commander so the Tiger stays
    /// in reserve; only the Tiger if it's the sole commander. nil when no trump
    /// of mine commands. Safe even for a defender: leading trump normally helps
    /// the declarer, but here I hold the controlling trump, so I win the round.
    func keepLeadTrumpLead(plays: [Card], trump: CardColor,
                           inference: TableInference) -> Card? {
        let commanders = plays.filter {
            $0.effectiveColor(trump: trump) == trump && inference.iControlColor($0)
        }
        guard !commanders.isEmpty else { return nil }
        if let lowBoss = commanders.filter({ !$0.isSpecial })
            .min(by: { rankOf($0) < rankOf($1) }) {
            return lowBoss
        }
        return commanders.min(by: { rankOf($0) < rankOf($1) })   // the Tiger alone
    }

    /// Defender's forcing surrender (principle 3): a worthless low card in a
    /// side color a NON-partner seat is known void in, so they must ruff (burn a
    /// trump) or let it run to my partner. Gated to LOW outstanding money in the
    /// color (`forceRuffMoneyCap`) so the forced ruff costs them a trump, not us
    /// a bank — the opposite of Hand-1-t7, where leading a void color full of
    /// money let the ruffer bank $70k. nil when no such low-money void exists.
    func forceRuffLead(plays: [Card], trump: CardColor,
                       inference: TableInference) -> Card? {
        // No trump left at the table → nothing to force out; the "ruff" lead
        // degenerates to a plain surrender and the safe exit handles that.
        guard inference.trumpStillOutInOpponentsAndPartner > 0 else { return nil }
        let myTeam = Seats.team(of: inference.me)
        func oppVoid(_ color: CardColor) -> Bool {
            Seats.all.contains {
                $0 != inference.me && Seats.team(of: $0) != myTeam
                    && inference.isKnownVoid($0, in: color)
            }
        }
        let targets = plays.filter { c in
            guard !c.isMoney, !c.isSpecial,
                  let color = c.effectiveColor(trump: trump), color != trump
            else { return false }
            return oppVoid(color) && inference.outstandingMoney(in: color) <= forceRuffMoneyCap
        }
        return targets.min { a, b in
            let ma = inference.outstandingMoney(in: a.effectiveColor(trump: trump) ?? trump)
            let mb = inference.outstandingMoney(in: b.effectiveColor(trump: trump) ?? trump)
            if ma != mb { return ma < mb }
            return rankOf(a) < rankOf(b)
        }
    }

    /// Cap on a color's live money for `forceRuffLead`: above this, forcing the
    /// ruff would hand the ruffer a bank, so we don't.
    var forceRuffMoneyCap: Int { 10_000 }

    // ---- Follow shortlist

    func followShortlist(view: PlayerView,
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
        // EFFECTIVE worth (Bull/Bear applied): a trick already Beared is worth
        // 0, so we must never bank money into it or fight to take it.
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
                // A Bull doubles a partner-winning money trick, and flips an
                // already-Beared one back to base×2 for us — a candidate even
                // when the trick is currently Beared. With NO money on the
                // table it's still a candidate: doubling $0 costs nothing and
                // partner's safe trick is a free exit for a Bull that would
                // otherwise be FORCED onto the final trick (doubling it for
                // whoever wins — the recurring endgame disaster).
                if !mustFollow, let bull = plays.first(where: { if case .bull = $0 { return true }; return false }) {
                    picks.append(bull)
                }
                // VALUE-SAFETY: if the trick is already Beared (worth 0), or a
                // loose Bear can still land on it from a yet-to-play opponent,
                // any money we add is wasted/fed to the Bear. In that case
                // offer ONLY the low non-money shed — no money-dump candidate.
                let bearThreat = !amLastToPlay
                    && inference.opponentCanBearTrick(led: led, currentTrick: trick)
                if !beared && !bearThreat {
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
                }
                // Hedge: cheapest non-money non-special. Never the Bear
                // (it would cancel partner's money trick — disastrous). This
                // is the only money-safe option under a Bear threat.
                let safeLow = pool.filter { !$0.isSpecial && !$0.isMoney }
                let lowPool = safeLow.isEmpty ? pool.filter { !$0.isSpecial } : safeLow
                if let lo = lowPool.min(by: { PlayoutPolicy.strength($0, led: led, trump: trump)
                                            < PlayoutPolicy.strength($1, led: led, trump: trump) }) {
                    picks.append(lo)
                }
                return picks
            }
        }

        // B. I can take it. A Beared trick is worth 0 — never fight for it or
        //    bank money into it; use effective value, not the raw money sum.
        let winners = pool.filter(wouldWin)
        let worthTaking = !beared && (effValue >= 5_000 || !partnerWinning)
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
            // BANK MONEY: when last to play the win is certain, so capturing
            // WITH a money card locks it in rather than stranding it for the
            // other team. Offer the highest-money winner as its own candidate
            // (the strength-based "big" above can pick a trump over money).
            if amLastToPlay,
               let bank = winners.filter({ $0.isMoney }).max(by: { $0.moneyValue < $1.moneyValue }) {
                picks.append(bank)
            }
            // BULL ESCAPE: winning a near-worthless pot is not obviously
            // better than ditching the Bull on it (it's only legal here
            // because we can't follow). Held too long, the Bull is FORCED
            // onto the final trick and doubles it for whoever wins — offer
            // the exit and let MCTS weigh it against taking the trick.
            // (Never onto a Beared trick: a Bull after the Bear flips the
            // trick back to ×2 for its winner.)
            if !beared, effValue <= 10_000,
               let bull = pool.first(where: { $0.isBull }) {
                picks.append(bull)
            }
            // Also a cheap shed in case "win" is more expensive than the
            // trick is worth.
            if let sh = cheapShed(pool, led: led, trump: trump) {
                picks.append(sh)
            }
            return picks
        }

        // C. Bear on opponent money trick we can't take. Lower the bar when a
        // loose Bull could still double the pot for their side.
        if !partnerWinning && !mustFollow {
            let bullDoubles = inference.opponentCanBullTrick(led: led, currentTrick: trick)
            // effValue is 0 if the trick is already Beared, so we never line up
            // a second, wasted Bear.
            if effValue >= 10_000 || (bullDoubles && moneyOnTable > 0) {
                if let bear = plays.first(where: { if case .bear = $0 { return true }; return false }) {
                    picks.append(bear)
                }
            }
        }

        // BULL ESCAPE on a trick we're not winning: when the pot is small the
        // Bull costs little here, while holding it risks the forced final-
        // trick double. Offer it; MCTS arbitrates. (Never onto a Beared
        // trick — a Bull after the Bear flips it back to ×2 for its winner.)
        if !partnerWinning, !beared, effValue <= 10_000,
           let bull = pool.first(where: { $0.isBull }) {
            picks.append(bull)
        }

        // D. Default — shed cheapest. When we're feeding an opponent-controlled
        // trick that already holds money, the Bull would double their take, so it
        // must NOT be offered as the cheap shed (the Bear stays cheap — it cancels).
        let bullIsCostly = !partnerWinning && moneyOnTable > 0
        if let lo = cheapShed(pool, led: led, trump: trump, bullIsCostly: bullIsCostly) {
            picks.append(lo)
        }
        if !mustFollow, let v = voidCreatingShed(pool: plays, view: view, trump: trump) {
            picks.append(v)
        }
        return picks
    }

    /// Can a yet-to-play seat overturn the partner-winning play?
    func canBeOverturned(trick: Trick,
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
    func voidCreatingShed(pool: [Card],
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

    func cheapShed(_ cards: [Card],
                            led: CardColor?,
                            trump: CardColor,
                            bullIsCostly: Bool = false) -> Card? {
        guard !cards.isEmpty else { return nil }
        return cards.min { a, b in
            if bullIsCostly && a.isBull != b.isBull { return b.isBull }
            if a.isMoney != b.isMoney { return !a.isMoney }
            if a.isSpecial != b.isSpecial { return !a.isSpecial }
            if a.moneyValue != b.moneyValue { return a.moneyValue < b.moneyValue }
            return PlayoutPolicy.strength(a, led: led, trump: trump)
                 < PlayoutPolicy.strength(b, led: led, trump: trump)
        }
    }

}

// MARK: - Card convenience

private extension Card {
    var suitColorOrNil: CardColor? {
        if case .colored(let c, _) = self { return c }
        return nil
    }
}
