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
//     • Agreement-mode redeal vote: KEEP the hand (decline the redeal) when
//       it values at/above the opening floor; otherwise agree to the redeal.
//       A redeal is triggered by ANY seat being money-poor, so a strong hand
//       of ours isn't surrendered just because another seat is short.
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

    let name: String
    let difficulty: Difficulty
    let seedBox: RNGBox

    init(name: String = "AI",
         difficulty: Difficulty = .normal,
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

        // Two decision stacks, chosen by the profile's style. `.traditional`
        // runs the legible principle ladder; `.adaptive` runs the MCTS/search
        // stack. Bidding and trick play fork by style; the remaining phases
        // (discard, trump, misdeal) are already heuristic and legible, so both
        // styles share them (Adaptive only differs in evaluator tables / rollout
        // bid eval, which those helpers read off `difficulty`).
        let traditional = (difficulty.style == .traditional)
        switch view.phase {
        case .bidding:         return traditional ? decideBidTraditional(view, legal: legal)
                                                  : decideBid(view, legal: legal)
        case .misdealDecision: return decideMisdeal(view, legal: legal)
        case .widowDiscard:    return decideDiscard(view, legal: legal)
        case .namingTrump:     return decideTrump(view, legal: legal)
        case .trickPlay:       return traditional ? decideTrickPlayTraditional(view, legal: legal)
                                                  : decideTrickPlay(view, legal: legal)
        case .handComplete:    return legal[0]
        }
    }

    // MARK: - Small helpers

    /// Near-tie preference for `decideTrickPlay` (lower tuple = preferred,
    /// compared lexicographically). Layers, in order:
    ///   1. specials are never spent on a tie (Tiger worst, then Bull/Bear);
    ///   2. CERTAIN money — when MY TEAM is safely taking the trick (I win it,
    ///      or a partner does uncontestably), BANK the most (−); otherwise
    ///      commit the LEAST (+) — both when donating to an opponent's trick
    ///      AND when leading (a led money card is exposed to the last, opponent,
    ///      player). `bankToOwnTeam` is false when leading (no winner yet);
    ///   3. conserve trump over off-suit;
    ///   4. lowest rank.
    /// Internal (not private) so the ordering is unit-testable without MCTS
    /// in the loop.
    static func tiePreference(_ c: Card, trump: CardColor,
                              bankToOwnTeam: Bool) -> (Int, Int, Int, Int) {
        let (special, money, isTrump) = tieKeyPrefix(c, trump: trump,
                                                     bankToOwnTeam: bankToOwnTeam)
        return (special, money, isTrump, PlayoutPolicy.rankOf(c))
    }

    /// The first three terms shared by `tiePreference` (Adaptive near-tie order)
    /// and `principledKey` (Traditional structural tie key): specials are never
    /// spent on a tie; CERTAIN money is banked (−) when our team safely takes the
    /// trick, else committed least (+); trump is conserved over off-suit. The two
    /// callers then diverge on the 4th term — `tiePreference` adds rank,
    /// `principledKey` adds controller-ness (rank becomes its residual).
    static func tieKeyPrefix(_ c: Card, trump: CardColor,
                             bankToOwnTeam: Bool) -> (Int, Int, Int) {
        let specialClass: Int
        switch c {
        case .tiger:       specialClass = 2
        case .bull, .bear: specialClass = 1
        default:           specialClass = 0
        }
        let moneyTerm = bankToOwnTeam ? -c.moneyValue : c.moneyValue
        let isTrump = (c.effectiveColor(trump: trump) == trump) ? 1 : 0
        return (specialClass, moneyTerm, isTrump)
    }

    func shouldBlunder() -> Bool {
        guard difficulty.blunderRate > 0 else { return false }
        return Double(seedBox.nextInt(upperBound: 10_000)) / 10_000.0
             < difficulty.blunderRate
    }
    func intRand(_ upper: Int) -> Int {
        upper <= 0 ? 0 : seedBox.nextInt(upperBound: upper)
    }
    func cardRank(_ c: Card) -> Int {
        if case .colored(_, let r) = c { return r.rawValue }
        return 0
    }
    func rankOf(_ c: Card) -> Int { PlayoutPolicy.rankOf(c) }

    func uniq(_ cards: [Card]) -> [Card] {
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
    func topOfEachColorInMyHand(_ hand: [Card],
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
