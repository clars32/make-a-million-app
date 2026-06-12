//
//  HandEvaluator.swift
//  Make-a-Million
//
//  Pure heuristic hand-valuation. The Monte Carlo agent calls this to
//  decide bidding, widow discards, and trump selection — the three places
//  where uniform-random opponent sampling is *worse* than reading the
//  cards in your hand and asking "what is this actually worth?"
//
//  Why heuristics, not rollouts, for these phases:
//
//   Bidding is fundamentally a hand-strength judgement. Rolling out from
//   pre-bidding requires deal sampling, but the unknown 42 cards are pure
//   noise — no public history yet to constrain them. So a million rollouts
//   tell you roughly what an average partner + average opponents do, which
//   is exactly the answer hand evaluation already gives, more cheaply and
//   more interpretably.
//
//   Discard / trump are forced choices late in setup. There IS information
//   to use (your 16-card hand, your widow knowledge), and a structural
//   evaluator captures it directly: count trump, count money, value
//   voids, value the Tiger.
//
//  The function returned is `evaluate(view:hand:assumingTrump:)` plus a
//  convenience `bestTrump(view:hand:)` that picks the strongest of the
//  four colors. Output is in DOLLARS — comparable directly to a bid.
//
//  TUNE: every numeric constant below. They are first-pass calibrations
//  designed so an "average" 13-card hand values around $130-150k (below
//  the $175k opening minimum), a decent hand $170-200k, a strong hand
//  $220-280k, and a monster hand $300k+. Watch AIArena win rates and the
//  bid-frequency distribution to retune.
//
//  ENGINE BINDING: Card.{effectiveColor,isSpecial,isMoney,moneyValue} ;
//  CardColor.allCases ; Card.Rank.rawValue ; Deck.totalMoneyInDeck ;
//  PlayerView.{me, myHand, widow, completedTricks, currentTrick}.
//

import Foundation

struct HandValuation {
    /// Expected GROSS the team captures with this trump choice. Comparable
    /// to a bid amount directly (the engine's contract test is
    /// `capturedByBidTeam >= bid`).
    let expectedGross: Int
    /// Per-color breakdown, so callers can see how forced the choice is.
    /// Sorted descending by value.
    let byColor: [(CardColor, Int)]
    /// The color that maximises expectedGross.
    let bestTrump: CardColor

    /// How decisive the best choice is. Large margin → trump is clear.
    /// Small → discard logic should be checked against alternative trumps.
    var trumpMargin: Int {
        guard byColor.count >= 2 else { return expectedGross }
        return byColor[0].1 - byColor[1].1
    }
}

enum HandEvaluator {

    /// Which constant set the valuation uses. `.original` is the hand-set
    /// baseline; `.calibrated` is fitted to the per-card realization rates
    /// measured by `AIArena.runCardCalibration` (June 2026). A/B lever —
    /// agents opt in via `MonteCarloAgent.Difficulty.calibratedValuation`,
    /// so challenger-vs-champion self-play can grade the refit before it
    /// becomes the default.
    nonisolated enum Tables { case original, calibrated }

    // MARK: - Public entry points

    /// Evaluate a hand assuming a specific trump color.
    static func evaluate(view: PlayerView,
                         hand: [Card],
                         assumingTrump trump: CardColor,
                         tables: Tables = .original) -> Int {
        let breakdown = breakdown(view: view, hand: hand, trump: trump,
                                  tables: tables)
        return breakdown.total
    }

    /// Try all four colors as trump and pick the best.
    static func bestValuation(view: PlayerView, hand: [Card],
                              tables: Tables = .original) -> HandValuation {
        var scores: [(CardColor, Int)] = []
        for color in CardColor.allCases {
            scores.append((color, evaluate(view: view, hand: hand,
                                           assumingTrump: color, tables: tables)))
        }
        scores.sort { $0.1 > $1.1 }
        return HandValuation(
            expectedGross: scores[0].1,
            byColor: scores,
            bestTrump: scores[0].0)
    }

    // MARK: - Decomposed breakdown (useful for debugging and tuning)

    struct Breakdown {
        var trumpMoney: Int = 0
        var trumpControl: Int = 0     // non-money trump tricks (11, low trump in length)
        var offSuitMoney: Int = 0
        var specials: Int = 0
        var voids: Int = 0
        var lengthBonus: Int = 0
        var partnerSupport: Int = 0
        var widowEV: Int = 0
        var total: Int {
            trumpMoney + trumpControl + offSuitMoney + specials
                + voids + lengthBonus + partnerSupport + widowEV
        }
    }

    static func breakdown(view: PlayerView,
                          hand: [Card],
                          trump: CardColor,
                          tables: Tables = .original) -> Breakdown {
        var b = Breakdown()

        let trumpCards = hand.filter { $0.effectiveColor(trump: trump) == trump }
        let trumpLen = trumpCards.count
        let hasTiger = hand.contains { if case .tiger = $0 { return true }; return false }

        b.trumpMoney   = scoreTrumpMoney(trumpCards, trumpLen: trumpLen, hasTiger: hasTiger,
                                         tables: tables)
        b.trumpControl = scoreTrumpControl(trumpCards, trumpLen: trumpLen)
        b.offSuitMoney = scoreOffSuitMoney(hand: hand, trump: trump, trumpLen: trumpLen,
                                           hasTiger: hasTiger, tables: tables)
        b.specials     = scoreSpecials(hand: hand, trump: trump, trumpLen: trumpLen)
        b.voids        = scoreVoidsAndShortness(hand: hand, trump: trump, trumpLen: trumpLen)
        b.lengthBonus  = scoreLengthBonus(trumpLen: trumpLen, hasTiger: hasTiger)
        b.partnerSupport = scorePartnerSupport(trumpLen: trumpLen, hasTiger: hasTiger,
                                               tables: tables)
        b.widowEV      = scoreWidowEV(view: view, tables: tables)

        return b
    }

    // MARK: - Components

    /// Money cards in the trump suit. These are *almost* sure to be captured
    /// by your team — high keep-probability scaled by your trump length and
    /// the Tiger. The keep probability captures the chance someone else
    /// trumps in over them (Tiger or higher trump) before you can cash them.
    private static func scoreTrumpMoney(_ trumpCards: [Card],
                                        trumpLen: Int,
                                        hasTiger: Bool,
                                        tables: Tables) -> Int {
        var sum = 0
        for c in trumpCards {
            guard case .colored(_, let r) = c, r.isMoney else { continue }
            let p = keepProbability(rank: r, trumpLen: trumpLen, hasTiger: hasTiger,
                                    tables: tables)
            sum += Int(Double(r.moneyValue) * p)
        }
        return sum
    }

    /// Non-money trump cards still produce tricks — specifically the 11
    /// (one below $15k) and any low trump that survives because you have
    /// length. Counts as "control value" rather than direct money.
    private static func scoreTrumpControl(_ trumpCards: [Card], trumpLen: Int) -> Int {
        var sum = 0
        for c in trumpCards {
            guard case .colored(_, let r) = c, !r.isMoney else { continue }
            // The 11 is a real winner (just below $15k of trump).
            if r == .eleven { sum += 6_000; continue }
            // 9, 8, 7 are tricks-in-length if trumpLen ≥ 5.
            if trumpLen >= 6 { sum += 2_500 }
            else if trumpLen >= 5 { sum += 1_500 }
            else if trumpLen >= 4 { sum += 500 }
        }
        return sum
    }

    /// Money cards in non-trump suits. They CAN be captured (lead them
    /// before the void shows up) but they're at the mercy of trumping.
    /// Win-probability scales with how many of THAT color you hold (longer
    /// = bigger chance no one's void yet) and inversely with trump exposure.
    private static func scoreOffSuitMoney(hand: [Card],
                                          trump: CardColor,
                                          trumpLen: Int,
                                          hasTiger: Bool,
                                          tables: Tables) -> Int {
        var sum = 0
        let byColor = Dictionary(grouping: hand) {
            $0.effectiveColor(trump: trump)
        }
        for color in CardColor.allCases where color != trump {
            let suit = byColor[color] ?? []
            for c in suit {
                guard case .colored(_, let r) = c, r.isMoney else { continue }
                let p = offSuitWinProbability(rank: r,
                                              suitLen: suit.count,
                                              trumpLen: trumpLen,
                                              hasTiger: hasTiger,
                                              tables: tables)
                sum += Int(Double(r.moneyValue) * p)
            }
        }
        return sum
    }

    /// Tiger, Bull, Bear. Each contributes a fixed expected value depending
    /// on context. The Tiger is the most valuable: it guarantees a trick
    /// AND draws out an opponent's biggest trump. Bull and Bear are
    /// situational; their value rises with trump control.
    private static func scoreSpecials(hand: [Card],
                                      trump: CardColor,
                                      trumpLen: Int) -> Int {
        var sum = 0
        for c in hand {
            switch c {
            case .tiger:
                // Tiger as trump-top: more valuable the more trump you have
                // (you can cash it once trumps are pulled, on a money trick).
                // Even bare, it guarantees a trick AND pulls opponent's
                // biggest non-Tiger trump out of their hand.
                sum += trumpLen >= 5 ? 45_000 :
                       trumpLen >= 3 ? 38_000 : 30_000
            case .bull:
                // Doubles a partner-winning money trick. Worth more with
                // trump control (you set up the trick).
                sum += trumpLen >= 5 ? 18_000 :
                       trumpLen >= 3 ? 12_000 : 6_000
            case .bear:
                // Cancels a money trick the opponents would take. Mainly
                // defensive; modest constant value.
                sum += 6_000
            default: break
            }
        }
        return sum
    }

    /// Voids and singletons in non-trump suits are tricks-you-can-trump
    /// IF you have the trump length to spend. With short trump these are
    /// nearly worthless and can actually hurt (opponents lead through you).
    private static func scoreVoidsAndShortness(hand: [Card],
                                               trump: CardColor,
                                               trumpLen: Int) -> Int {
        guard trumpLen >= 4 else { return 0 }
        let trumpEnergy: Double = trumpLen >= 6 ? 1.0
                                : trumpLen == 5 ? 0.7
                                : 0.4
        var sum = 0
        var byColor: [CardColor: Int] = [:]
        for c in hand {
            if let ec = c.effectiveColor(trump: trump), ec != trump {
                byColor[ec, default: 0] += 1
            }
        }
        for color in CardColor.allCases where color != trump {
            let n = byColor[color] ?? 0
            switch n {
            case 0: sum += Int(15_000 * trumpEnergy)   // a void: cash trump on their money
            case 1: sum += Int(6_000  * trumpEnergy)   // singleton: void after one round
            case 2: sum += Int(2_000  * trumpEnergy)   // doubleton: maybe void
            default: break
            }
        }
        return sum
    }

    /// Trump length itself — beyond what individual cards capture — has
    /// strategic value (you can pull trumps and run side suits cleanly).
    /// Negative below 3, because you'll get over-trumped.
    private static func scoreLengthBonus(trumpLen: Int, hasTiger: Bool) -> Int {
        let tigerBonus = hasTiger ? 4_000 : 0
        // Short-trump penalty eased (June 2026 calibration): the declarer
        // names trump on the 16-card hand (after the widow), so "short" trump
        // is less of a death sentence than the raw 13-card count implies.
        switch trumpLen {
        case 0...2: return -4_000 + tigerBonus
        case 3: return 2_000 + tigerBonus
        case 4: return 6_000 + tigerBonus
        case 5: return 18_000 + tigerBonus
        case 6: return 30_000 + tigerBonus
        default: return 42_000 + tigerBonus
        }
    }

    /// As declarer, your partner contributes incidental tricks on the side
    /// — their high cards in non-trump suits, their occasional ability to
    /// take an opponent's money. Scales with your trump control: the
    /// stronger you are, the more your partner can capitalise.
    private static func scorePartnerSupport(trumpLen: Int, hasTiger: Bool,
                                            tables: Tables) -> Int {
        // CALIBRATED (June 2026, runCardCalibration residual block, pooled
        // 360 deals): the non-money components under-predict the realized
        // residual (team gross minus the declarer's own realized money) by
        // +$37k at trump length 5 and +$9k at 6+; length 4 measured +$54k
        // but on n=68 hands, so it gets a damped +$43k. Short-trump
        // declarers still harvest $130k+ of partner/incidental capture —
        // the original constants over-penalised them. This is the
        // per-length knob, so the correction lands here.
        if case .calibrated = tables {
            switch (trumpLen, hasTiger) {
            case (6..., true):  return 81_000
            case (6..., false): return 71_000
            case (5,    true):  return 101_000
            case (5,    false): return 91_000
            case (4,    true):  return 95_000
            case (4,    false): return 88_000
            default:            return 40_000   // ≤3: unmeasured (rare post-widow)
            }
        }
        // Partner statistically has ~$94k of money; when you control the
        // play, they routinely contribute $40-50k of incidental capture.
        // Earlier numbers were calibrated against a weaker estimator and
        // left the agent passing on hands a real player would bid.
        // Recalibrated upward (June 2026): the counterfactual-declarer
        // calibration showed the team captures ~$100k more than the old
        // estimate predicted, with most of the gap on the partner/incidental
        // side. We close ~half of it here (the cleanest team-gross lever),
        // targeting a ~15% set-rate rather than the old over-cautious ~7%.
        switch (trumpLen, hasTiger) {
        case (6..., true):  return 72_000
        case (6..., false): return 62_000
        case (5,    true):  return 64_000
        case (5,    false): return 54_000
        case (4,    true):  return 52_000
        case (4,    false): return 45_000
        default:            return 36_000
        }
    }

    /// Expected value of the widow if it has not been revealed to us yet.
    /// Once we're past bidding the widow is in our hand and worth nothing
    /// extra to count here.
    private static func scoreWidowEV(view: PlayerView, tables: Tables) -> Int {
        guard view.phase == .bidding else { return 0 }
        // CALIBRATED (June 2026): the 1.30 fudge below was silently absorbing
        // the per-card under-prediction that the calibrated tables now carry
        // honestly. Back to the plain exchange value: ~$22k of average widow
        // money plus a little selection value (declarer keeps the best 13 of
        // 16). This is the bid-frame re-zero knob — runBidCalibration
        // adjudicates it after any table change.
        if case .calibrated = tables {
            let avg = (3 * Deck.totalMoneyInDeck) / 55       // ~$21.8k
            return avg + 4_000                                // net ~$26k
        }
        // Average widow gross is ~$22k (3 cards × $400k/55 cards).
        // We discard 3 low cards worth ~$5k of capture potential, so net
        // gain is ~$17k. Slightly discount further because not every widow
        // pick-up improves the hand strongly.
        // The declarer takes 3 widow cards and keeps the best of the enlarged
        // hand — worth more than a flat average suggests. Calibration showed
        // the old ~$15k net was too low.
        let avg = (3 * Deck.totalMoneyInDeck) / 55           // ~$21.8k
        return Int(Double(avg) * 1.30) + 6_000               // net ~$34k
    }

    // MARK: - Probability helpers (TUNE)
    //
    // Internal (not private) so AIArena.runCardCalibration can print the
    // model's predicted p next to the observed realization rate per cell —
    // these tables are tuned against that instrument, not by hand.

    /// How likely a trump money card survives to be captured.
    /// Length protects (your low trump shields the high). Tiger protects
    /// the top (no over-trump above $40k).
    static func keepProbability(rank: Card.Rank,
                                trumpLen: Int,
                                hasTiger: Bool,
                                tables: Tables = .original) -> Double {
        // CALIBRATED (June 2026, runCardCalibration, pooled 360 deals /
        // 1440 playouts at two independent seeds): the original table was
        // too optimistic at short trump length — observed realization ran
        // well below prediction at length 4-5 and was calibrated at 6.
        // Fitted as a direct (rank × trump length) table because the length
        // slope is RANK-DEPENDENT — an additive adjustment can't express it:
        // low money needs length protection badly (the $5k climbs 66→81%
        // from length 5 to 7+) while the $30k is flat ~88% at 5+, and the
        // $40k only loses to the Tiger/Bear at all. The small Tiger overlay
        // is deliberately gentler than the raw with/without marginal (~11pp),
        // which is mostly length confounding — Tiger holders have longer
        // trump, and the Tiger itself counts toward length.
        if case .calibrated = tables {
            let row: [Double]   // trump length ≤2, 3, 4, 5, 6, 7+
            switch rank {
            case .money40k: row = [0.64, 0.72, 0.84, 0.89, 0.96, 0.97]
            case .money30k: row = [0.54, 0.62, 0.74, 0.87, 0.90, 0.88]
            case .money15k: row = [0.46, 0.54, 0.66, 0.73, 0.84, 0.86]
            case .money10k: row = [0.45, 0.53, 0.65, 0.70, 0.80, 0.81]
            case .money5k:  row = [0.33, 0.41, 0.53, 0.64, 0.73, 0.79]
            default:        return 0
            }
            let col = trumpLen <= 2 ? 0 : (trumpLen >= 7 ? 5 : trumpLen - 2)
            let tigerAdj: Double = hasTiger ? 0.025 : -0.010
            return max(0.10, min(0.99, row[col] + tigerAdj))
        }
        // Base probability climbs with rank — the $40k of trump is nearly
        // safe, the $5k is exposed unless protected by length.
        var p: Double
        switch rank {
        case .money40k: p = hasTiger ? 0.97 : 0.92
        case .money30k: p = 0.88
        case .money15k: p = 0.80
        case .money10k: p = 0.72
        case .money5k:  p = 0.62
        default:        return 0
        }
        // Length adjusts both directions: short trump can't protect
        // anything; long trump locks them in.
        let lenAdj: Double
        switch trumpLen {
        case 0...2: lenAdj = -0.30
        case 3:     lenAdj = -0.10
        case 4:     lenAdj =  0.00
        case 5:     lenAdj =  0.05
        case 6:     lenAdj =  0.08
        default:    lenAdj =  0.10
        }
        return max(0.10, min(0.98, p + lenAdj))
    }

    /// How likely an off-suit money card wins its trick. Driven by RANK
    /// (the $40k is the top of its color so it usually wins on a clean
    /// lead) and by SUIT LENGTH (if you have many of a color, opponents
    /// are short, less likely to be void early, more likely to follow).
    static func offSuitWinProbability(rank: Card.Rank,
                                      suitLen: Int,
                                      trumpLen: Int,
                                      hasTiger: Bool,
                                      tables: Tables = .original) -> Double {
        // CALIBRATED (June 2026, runCardCalibration, pooled 360 deals /
        // 1440 playouts at two independent seeds): the original model
        // asked "does this card win its own trick?" — but value is realized
        // whenever the TEAM captures the trick the card lands in (shed onto
        // partner's winner, banked on a won trick), and a declarer's team
        // wins well over half the tricks. Observed: low money realizes a
        // ~40-50% team baseline; mid money ($15k/$10k) rises gently with
        // suit length; the $30k sits ~70% except as a singleton (~50% — one
        // shot, loses to the $40k holder); the $40k cashes ~90-100% with a
        // NEGATIVE length slope (a singleton cashes round one before voids
        // develop — the original positive length adjustment pointed the
        // wrong way). Fitted as a direct (rank × suit length) table; trump
        // length measured flat ≥4, small penalty kept for unmeasured ≤3;
        // no Tiger effect measured (92.0 vs 91.7 on the off-suit $40k).
        if case .calibrated = tables {
            let p: Double
            switch rank {
            case .money40k: p = suitLen <= 1 ? 0.98 : suitLen == 2 ? 0.94
                              : suitLen == 3 ? 0.90 : 0.90
            case .money30k: p = suitLen <= 1 ? 0.50 : suitLen == 2 ? 0.68
                              : suitLen == 3 ? 0.73 : 0.70
            case .money15k: p = suitLen <= 1 ? 0.40 : suitLen == 2 ? 0.48
                              : suitLen == 3 ? 0.56 : 0.54
            case .money10k: p = suitLen <= 1 ? 0.40 : suitLen == 2 ? 0.44
                              : suitLen == 3 ? 0.49 : 0.51
            case .money5k:  p = suitLen <= 1 ? 0.39 : suitLen == 2 ? 0.42
                              : suitLen == 3 ? 0.41 : 0.43
            default: return 0
            }
            let trumpAdj: Double = trumpLen <= 3 ? -0.05 : 0.0
            return max(0.02, min(0.98, p + trumpAdj))
        }
        // Bases raised (June 2026 calibration): as the declarer you control
        // trump and tempo, so side-suit money is cashed more often than the
        // old, very pessimistic figures assumed — especially the mid ranks.
        let base: Double
        switch rank {
        case .money40k: base = 0.82   // top of color, can still be trumped
        case .money30k: base = 0.52   // often loses to the $40k if you don't have it
        case .money15k: base = 0.28
        case .money10k: base = 0.16
        case .money5k:  base = 0.09
        default: return 0
        }
        // Longer in a color → leads find followers, less risk of trumping.
        let lenAdj: Double = suitLen >= 4 ? 0.10
                           : suitLen == 3 ? 0.05
                           : suitLen == 2 ? 0.00
                           : -0.05
        // More opponent trump out → more risk of being trumped.
        // Your own trumpLen approximates how short opponents are.
        let trumpAdj: Double = trumpLen >= 6 ? 0.10
                             : trumpLen >= 5 ? 0.06
                             : trumpLen >= 4 ? 0.02
                             : -0.05
        // Tiger is the loose top trump — a small extra penalty on big
        // off-suit money since it can be killed by the Tiger or Bull.
        let tigerAdj: Double = hasTiger ? 0.0 : (rank == .money40k ? -0.05 : 0.0)
        return max(0.02, min(0.95, base + lenAdj + trumpAdj + tigerAdj))
    }
}
