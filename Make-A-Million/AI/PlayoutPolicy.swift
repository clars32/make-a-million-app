//
//  PlayoutPolicy.swift
//  Make-a-Million
//
//  REWRITE — a tactically aware rollout policy. The Monte Carlo agent
//  calls this thousands of times per decision to roll determinized worlds
//  forward to handComplete. The previous version was a thin "play low,
//  take when you can" sketch; this one encodes the bulk of the strategic
//  principles a strong human player uses, expressed in code that is
//  cheap enough to be called inside an MCTS rollout.
//
//  WHY: in trick-taking games with hidden information, uniform-random
//  rollouts are famously weak — they wash out the very signal MCTS is
//  trying to estimate (who wins this trick, is there money on the table,
//  is partner already winning). A smarter playout converges far faster,
//  *especially* on bidding-relevant evaluation. This is the single
//  highest-leverage piece of the whole AI stack to tune.
//
//  Note: the playout runs over a DETERMINIZED full-information state.
//  It is therefore allowed to read every seat's hand — that's the entire
//  point of MCTS-on-PIMC. The hidden information lives in the SAMPLING
//  (AIWorld.swift), not in the playout.
//
//  PRINCIPLES ENCODED (mapped to user's list):
//
//   1. "$40k first time a color is led" — when leading and the color is
//      virgin (no completed trick has been led in it), lead our $40k of
//      a side-suit if we hold it.
//   2. "Lead others out of trump" — as the declarer with trump length
//      and the Tiger still loose, lead low trump to draw it.
//   3. "Big money protection" — never volunteer big trump money before
//      the Tiger is accounted for; never lead it AT ALL until pulled.
//   4. "Don't waste $30k after partner's $40k" — when forced to follow,
//      we dump LOW (only follow with a money card if it's the smallest
//      we have of the color).
//   5. "Dump money on partner's safe trick" — when partner is winning
//      and the win is safe (no over-trump risk from yet-to-play seats),
//      shed our highest money of the led color.
//   6. "Slip big money on opponent's already-resolving trick" — when
//      forced and partner can't help, dump small; save big for the
//      tricks you can actually take.
//   7. "Bull doubles partner's money trick", "Bear cancels opponent's
//      money trick" — Bull on partner-winning, Bear on opponent-winning
//      tricks with money on the table.
//   8. "Try to void" — when discarding and you have only one of a side
//      suit, get rid of it (used at the leading-low fallback).
//
//  ENGINE BINDING: GameState.{phase, currentTrick, trump, highBidder,
//  hands, capturedByTeam, completedTricks, toAct, legalMoves(for:)} ;
//  GameState.trickWinner(_:trump:) ; Trick.ledColor(trump:) ;
//  Card.{effectiveColor, isSpecial, isMoney, moneyValue} ; Seats.{team,
//  count, all, next}.
//

import Foundation

enum PlayoutPolicy {

    /// Pick a legal move for `seat` in `state`. Guarantees: returns a
    /// move from `state.legalMoves(for: seat)`. Total over all phases.
    /// `commandingPull`: A/B-gated rollout improvement — when the declarer
    /// draws trump, lead a commanding HIGH trump (one no other seat can beat)
    /// instead of always the lowest, so the round is won and the lead kept.
    /// `specialEscape`: A/B-gated rollout improvement — Bull endgame
    /// management (shed the Bull on worthless tricks late; when trapped with
    /// BER+BUL as the last two cards, spend the Bull small and keep the Bear).
    /// Defaults off preserve the previous rollout behaviour exactly (and keep
    /// the `move(in:seat:)` API stable for the golden tactics tests).
    static func move(in state: GameState, seat: PlayerID,
                     commandingPull: Bool = false,
                     specialEscape: Bool = false) -> Move {
        let moves = state.legalMoves(for: seat)
        precondition(!moves.isEmpty,
                     "PlayoutPolicy asked to move with no legal moves "
                     + "(phase = \(state.phase))")
        if moves.count == 1 { return moves[0] }

        switch state.phase {
        case .bidding:
            // Rollouts are constructed at/after the declarer is known, so
            // we should never have to bid here. Pass if we can; otherwise
            // the cheapest action keeps the loop total.
            return moves.first { $0.isPass } ?? moves[0]

        case .misdealDecision:
            // Defensive: rollouts run against `.disabled` worlds and never
            // reach this phase. The forced move is the only legal one.
            return .callMisdeal

        case .widowDiscard:
            return cheapestDiscard(moves)

        case .namingTrump:
            // Real trump choice is always made by the agent (which evaluates
            // all four colors), never inside a rollout. Safety fallback.
            return moves[0]

        case .trickPlay:
            return trickMove(in: state, seat: seat, legal: moves,
                             commandingPull: commandingPull,
                             specialEscape: specialEscape)

        case .handComplete:
            return moves[0]
        }
    }

    // MARK: - Trick play (the part that matters)

    private static func trickMove(in state: GameState,
                                  seat: PlayerID,
                                  legal: [Move],
                                  commandingPull: Bool,
                                  specialEscape: Bool) -> Move {
        guard let trump = state.trump else { return legal[0] }
        let plays = legal.compactMap { $0.playedCard }
        guard !plays.isEmpty else { return legal[0] }

        let trick = state.currentTrick
        let onTable = trick?.plays ?? []
        let isLeading = onTable.isEmpty
        let amDeclarer = (seat == state.highBidder)

        if isLeading {
            return .play(chooseLead(plays: plays,
                                    state: state,
                                    seat: seat,
                                    trump: trump,
                                    amDeclarer: amDeclarer,
                                    commandingPull: commandingPull))
        } else {
            return .play(chooseFollow(plays: plays,
                                      onTable: onTable,
                                      trickLeader: trick?.leader ?? seat,
                                      state: state,
                                      seat: seat,
                                      trump: trump,
                                      specialEscape: specialEscape))
        }
    }

    // MARK: - Leading

    private static func chooseLead(plays: [Card],
                                   state: GameState,
                                   seat: PlayerID,
                                   trump: CardColor,
                                   amDeclarer: Bool,
                                   commandingPull: Bool = false) -> Card {

        // Helper: has this color been led in any completed trick?
        func colorLed(_ color: CardColor) -> Bool {
            for t in state.completedTricks {
                for pc in t.plays {
                    if pc.card.effectiveColor(trump: trump) == color {
                        return true
                    }
                }
            }
            return false
        }

        // How much trump is still out among other seats?
        let trumpStillOut: Int = {
            var count = 0
            for (s, hand) in state.hands where s != seat {
                count += hand.filter { $0.effectiveColor(trump: trump) == trump }.count
            }
            return count
        }()
        let tigerStillOut: Bool = state.hands.contains { (s, hand) in
            s != seat && hand.contains(where: { if case .tiger = $0 { return true }; return false })
        }

        let myTrump = plays.filter { $0.effectiveColor(trump: trump) == trump }
        let myNonTrump = plays.filter { $0.effectiveColor(trump: trump) != trump && !$0.isSpecial }

        // ---- 1. Pull trumps (declarer principle).
        //
        // As declarer with strong trump and the Tiger or large trump still
        // loose, draw it out. By default lead a LOW trump (not money, not the
        // Tiger). With `commandingPull` (A/B), if we hold a HIGH trump that no
        // other seat can beat, lead THAT instead — the round still wins and we
        // keep the lead, rather than donating it (and any banked money) to an
        // opponent's higher trump. Full-info rollout, so we can read the table.
        if amDeclarer && trumpStillOut >= 2 && myTrump.count >= 4 {
            if commandingPull {
                let highestOtherTrump = state.hands
                    .filter { $0.key != seat }
                    .flatMap { $0.value }
                    .filter { $0.effectiveColor(trump: trump) == trump }
                    .map { rankOf($0) }
                    .max() ?? -1
                let commander = myTrump
                    .filter { !$0.isSpecial && rankOf($0) > highestOtherTrump }
                    .max { rankOf($0) < rankOf($1) }
                if let c = commander { return c }
            }
            let lowTrump = myTrump
                .filter { !$0.isMoney && !$0.isSpecial }
                .min { rankOf($0) < rankOf($1) }
            if let c = lowTrump { return c }
        }

        // ---- 2. $40k of a virgin side suit.
        //
        // First time a color is led, the $40k is unlikely to be trumped
        // (opponents probably aren't void yet) and locks in $40k+.
        for color in CardColor.allCases where color != trump {
            if colorLed(color) { continue }
            for c in myNonTrump where c.effectiveColor(trump: trump) == color {
                if case .colored(_, let r) = c, r == .money40k { return c }
            }
        }

        // ---- 3. Cash a sure winner in a side suit.
        //
        // If I hold a card that no other seat can beat IN ITS COLOR and
        // no one is yet void in that color, lead it. This applies to
        // mid-rank money like $30k once the $40k of that color is gone.
        if let safe = sureWinnerNonTrump(plays: plays, state: state, seat: seat, trump: trump) {
            return safe
        }

        // ---- 4. If trumps are pulled, cash high trump.
        if trumpStillOut == 0 && !tigerStillOut {
            // Highest trump first — Tiger or top trump money.
            if let high = myTrump.max(by: { rankOf($0) < rankOf($1) }) {
                return high
            }
        }

        // ---- 5. Default: lead a low non-money, non-special card.
        //
        // Prefer a card from our shortest non-trump suit (heading toward
        // a void) — "try to void another color".
        if let lowSafe = lowSafeLead(plays: myNonTrump, hand: state.hands[seat] ?? []) {
            return lowSafe
        }

        // ---- 6. Last resort: cheapest of whatever's legal.
        return plays.min { strength($0, led: nil, trump: trump)
                         < strength($1, led: nil, trump: trump) }!
    }

    /// Returns my lowest non-money, non-special card, preferring one from
    /// my shortest non-trump suit (so a follow-up trump-lead voids it).
    private static func lowSafeLead(plays: [Card], hand: [Card]) -> Card? {
        let candidates = plays.filter { !$0.isMoney && !$0.isSpecial }
        guard !candidates.isEmpty else { return nil }
        // Group by raw color (these are all .colored cards).
        var bySuit: [CardColor: Int] = [:]
        for c in hand {
            if case .colored(let col, _) = c { bySuit[col, default: 0] += 1 }
        }
        return candidates.min { a, b in
            let sa = a.suitColor.map { bySuit[$0] ?? 0 } ?? 99
            let sb = b.suitColor.map { bySuit[$0] ?? 0 } ?? 99
            if sa != sb { return sa < sb }                  // shorter suit first
            return rankOf(a) < rankOf(b)                    // then lowest rank
        }
    }

    /// A non-trump card I hold that no other seat can beat in its color
    /// AND no other seat is known void in that color (so they'll follow,
    /// not trump). Used to cash a clean $40k/$30k.
    private static func sureWinnerNonTrump(plays: [Card],
                                           state: GameState,
                                           seat: PlayerID,
                                           trump: CardColor) -> Card? {
        let nonTrump = plays.filter {
            !$0.isSpecial && $0.effectiveColor(trump: trump) != trump
        }
        for card in nonTrump.sorted(by: { rankOf($0) > rankOf($1) }) {
            guard let color = card.effectiveColor(trump: trump) else { continue }
            // Is anything higher of that color still in another seat?
            let myRank = rankOf(card)
            var beaten = false
            for (s, hand) in state.hands where s != seat {
                for c in hand {
                    if c.effectiveColor(trump: trump) == color && rankOf(c) > myRank {
                        beaten = true; break
                    }
                }
                if beaten { break }
            }
            if beaten { continue }
            // Anyone void in this color? Then they can trump or sluff.
            var canBeTrumped = false
            for (s, hand) in state.hands where s != seat {
                let hasColor = hand.contains { $0.effectiveColor(trump: trump) == color }
                let hasTrump = hand.contains { $0.effectiveColor(trump: trump) == trump }
                if !hasColor && hasTrump { canBeTrumped = true; break }
            }
            if canBeTrumped { continue }
            return card
        }
        return nil
    }

    // MARK: - Following

    private static func chooseFollow(plays: [Card],
                                     onTable: [PlayedCard],
                                     trickLeader: PlayerID,
                                     state: GameState,
                                     seat: PlayerID,
                                     trump: CardColor,
                                     specialEscape: Bool = false) -> Card {
        let provisional = Trick(leader: trickLeader, plays: onTable)
        let currentWinner = GameState.trickWinner(provisional, trump: trump)
        let partnerWinning = Seats.team(of: currentWinner) == Seats.team(of: seat)
                          && currentWinner != seat
        let moneyOnTable = onTable.reduce(0) { $0 + $1.card.moneyValue }
        // EFFECTIVE worth: a Bear already on the table makes the trick worth 0,
        // a Bull doubles it. Decisions about whether to fight for or bank into
        // this trick must use this, NOT the raw money sum.
        let effValue = tableValue(onTable)
        let beared = tableIsBeared(onTable)
        let led = provisional.ledColor(trump: trump)
        let amLastToPlay = onTable.count == Seats.count - 1

        // Can I follow the led color? (Engine has already filtered to
        // legal moves, but knowing this changes our strategy.)
        let mustFollow = led != nil
            && plays.contains { $0.effectiveColor(trump: trump) == led }
        let followingPool = mustFollow
            ? plays.filter { $0.effectiveColor(trump: trump) == led }
            : plays

        func wouldWin(_ c: Card) -> Bool {
            var t = onTable
            t.append(PlayedCard(player: seat, card: c))
            return GameState.trickWinner(
                Trick(leader: trickLeader, plays: t), trump: trump) == seat
        }

        // ---- Partner already winning.
        if partnerWinning {
            // Is partner's win safe? Safe iff:
            //   (a) I am last to play (no over-trump possible), OR
            //   (b) no one yet-to-play can over-trump or over-rank.
            let safe = amLastToPlay || partnerWinSafe(state: state,
                                                       seat: seat,
                                                       trickLeader: trickLeader,
                                                       onTable: onTable,
                                                       trump: trump)
            if safe {
                // A Bull doubles a partner-winning money trick — and flips an
                // already-Beared one back to base×2 for us. Worth it whenever
                // real base money is present, so try it first. Under
                // specialEscape, partner's safe trick is ALSO the free exit
                // for a Bull late in the hand (doubling $0 costs nothing, and
                // a Bull carried to the last card is forced onto the final
                // trick, doubling it for whoever wins).
                if !mustFollow, let bull = plays.first(where: { $0.isBull }),
                   moneyOnTable > 0
                    || (specialEscape && (state.hands[seat]?.count ?? 13) <= 6) {
                    return bull
                }
                // VALUE-SAFETY (not just rank-safety): adding money is pointless
                // if the trick is ALREADY Beared (worth 0), or if a yet-to-play
                // opponent can still Bear it. In both cases shed the LEAST value
                // possible — never our money, never the Bear itself.
                let bearThreat = !amLastToPlay
                    && opponentCanPlayBear(state: state, seat: seat,
                                           onTable: onTable, led: led, trump: trump)
                if beared || bearThreat {
                    return cheapestShed(followingPool, led: led, trump: trump)
                }
                // Dump money — but PRESERVE secondary controllers
                // (principle 8: don't dump $30k on partner's $40k; keep
                // it to win the next round of that color).
                let myTops = topOfEachColorInHand(state.hands[seat] ?? [], trump: trump)
                let nonControllers = followingPool.filter { c in
                    guard let color = c.effectiveColor(trump: trump) else { return true }
                    return myTops[color] != c
                }
                let dumpFrom = nonControllers.isEmpty ? followingPool : nonControllers
                if let dump = highestMoneyDump(dumpFrom) {
                    return dump
                }
                // No money worth dumping — shed lowest non-special.
                // CRITICAL: never let Bear sneak through here, it would
                // cancel partner's money trick.
                let safePool = dumpFrom.filter { !$0.isSpecial }
                let lowPool = safePool.isEmpty ? dumpFrom : safePool
                if let lo = lowPool.min(by: { strength($0, led: led, trump: trump)
                                            < strength($1, led: led, trump: trump) }) {
                    return lo
                }
            }
            // Not safe — fall through to "try to win or shed low" logic.
        }

        // ---- SPECIAL-ESCAPE (A/B-gated): Bull endgame management.
        // The Bull only ever helps a trick OUR side wins; carried too long it
        // is FORCED onto/into the final trick and doubles it for whoever wins
        // (the recurring "$160k trick-13" leak). The default shed comparator
        // sorts specials last unconditionally, so without this rule EVERY
        // rollout's future self is endplayed the same way — the catastrophe is
        // constant across root candidates and cancels out of the MCTS
        // comparison, hiding the leak from search.
        if specialEscape, !partnerWinning,
           let bull = plays.first(where: { $0.isBull }) {
            let myCount = state.hands[seat]?.count ?? 13
            // Trapped with BER+BUL as the last two cards: spend the BULL on
            // the small pot and keep the BEAR — it can still cancel a big
            // trick, and a trapped Bear is harmless (a forced Bear lead
            // cancels its own trick). The shed comparator alone does the
            // exact opposite.
            if myCount == 2, !beared, plays.contains(where: { $0.isBear }) {
                let outstanding = state.hands
                    .filter { $0.key != seat }
                    .flatMap(\.value)
                    .reduce(0) { $0 + $1.moneyValue }
                if outstanding > 2 * effValue { return bull }
            }
            // Cheap exit late in the hand: ditch the Bull on a worthless pot
            // rather than carry it into the forced final-trick double. (Never
            // onto a Beared trick — a Bull after the Bear flips the trick
            // back to ×2 for its winner.)
            if myCount <= 6, !beared,
               moneyOnTable == 0 || (amLastToPlay && effValue <= 5_000) {
                return bull
            }
        }

        // ---- I can take the trick AND it's worth taking.
        // A Beared trick is worth 0 — never fight for it, and above all never
        // bank money into it. Use the EFFECTIVE value, not the raw money sum.
        let winners = followingPool.filter(wouldWin)
        let worthTaking = !beared && (effValue >= 5_000 || !partnerWinning)
        if !winners.isEmpty && worthTaking {
            // BANK MONEY when last to play: I am certain to win (no one plays
            // after me), so capture WITH a money card rather than shedding a
            // low one and stranding money that the other team may take later.
            // (Only reached when the trick is NOT Beared, so the money counts.)
            if amLastToPlay {
                let moneyWinners = winners.filter { $0.isMoney }
                if let bank = moneyWinners.max(by: { $0.moneyValue < $1.moneyValue }) {
                    return bank
                }
            }
            // Otherwise take it as cheaply as possible — don't waste the Tiger
            // on a low trick.
            let cheapest = winners.min { strength($0, led: led, trump: trump)
                                       < strength($1, led: led, trump: trump) }!
            return cheapest
        }

        // ---- Can't / shouldn't win. Bear off an opponent's money trick.
        // Lower the threshold when an opponent can still drop a loose Bull
        // (which DOUBLES the money heading to their side): even a modest pot
        // is worth cancelling then. effValue is 0 if already Beared, so we
        // never waste a second Bear.
        if !partnerWinning, !mustFollow,
           let bear = plays.first(where: { if case .bear = $0 { return true }; return false }) {
            let bullDoubles = opponentCanPlayBull(state: state, seat: seat,
                                                  onTable: onTable, led: led, trump: trump)
            if effValue >= 10_000 || (bullDoubles && moneyOnTable > 0) {
                return bear
            }
        }

        // ---- Shed the least valuable card. If we're feeding an opponent-controlled
        // trick that already holds base money, the Bull is NOT cheap — it would
        // double their take — so steer the shed away from it.
        let bullIsCostly = !partnerWinning && moneyOnTable > 0
        return cheapestShed(followingPool, led: led, trump: trump,
                            bullIsCostly: bullIsCostly)
    }

    /// Is partner's currently-winning card safe from over-trump / over-rank
    /// by anyone who has not yet played?
    private static func partnerWinSafe(state: GameState,
                                       seat: PlayerID,
                                       trickLeader: PlayerID,
                                       onTable: [PlayedCard],
                                       trump: CardColor) -> Bool {
        // Who's still to play (excluding me)?
        let played = Set(onTable.map(\.player))
        let yetToPlay = Seats.all.filter {
            !played.contains($0) && $0 != seat
        }
        if yetToPlay.isEmpty { return true }

        let provisional = Trick(leader: trickLeader, plays: onTable)
        let winner = GameState.trickWinner(provisional, trump: trump)
        let winnerCard = onTable.first { $0.player == winner }!.card
        let winnerStrength = strength(winnerCard,
                                      led: provisional.ledColor(trump: trump),
                                      trump: trump)
        for s in yetToPlay {
            guard let hand = state.hands[s] else { continue }
            for c in hand {
                if strength(c, led: provisional.ledColor(trump: trump),
                            trump: trump) > winnerStrength {
                    return false
                }
            }
        }
        return true
    }

    /// Could a yet-to-play OPPONENT legally play the Bear into this trick
    /// (cancelling its money)? Full-information: the rollout reads hands. A
    /// seat may only play the Bear when it cannot follow the led color (or
    /// the Bear is its last card). Used to avoid feeding money to a trick
    /// that is about to be zeroed.
    private static func opponentCanPlayBear(state: GameState,
                                            seat: PlayerID,
                                            onTable: [PlayedCard],
                                            led: CardColor?,
                                            trump: CardColor) -> Bool {
        opponentCanPlaySpecial(state: state, seat: seat, onTable: onTable,
                               led: led, trump: trump) { card in
            if case .bear = card { return true }; return false
        }
    }

    /// Symmetric check for the Bull (which DOUBLES the trick's money for the
    /// capturing side). Relevant when opponents are taking the trick.
    private static func opponentCanPlayBull(state: GameState,
                                            seat: PlayerID,
                                            onTable: [PlayedCard],
                                            led: CardColor?,
                                            trump: CardColor) -> Bool {
        opponentCanPlaySpecial(state: state, seat: seat, onTable: onTable,
                               led: led, trump: trump) { card in
            if case .bull = card { return true }; return false
        }
    }

    private static func opponentCanPlaySpecial(state: GameState,
                                               seat: PlayerID,
                                               onTable: [PlayedCard],
                                               led: CardColor?,
                                               trump: CardColor,
                                               _ isWanted: (Card) -> Bool) -> Bool {
        let played = Set(onTable.map(\.player))
        for s in Seats.all where !played.contains(s) && s != seat {
            guard Seats.team(of: s) != Seats.team(of: seat) else { continue }
            guard let hand = state.hands[s], hand.contains(where: isWanted) else { continue }
            // A special is legal only when the seat cannot follow the led
            // color, or it is the seat's only remaining card.
            let canFollow = led != nil
                && hand.contains { $0.effectiveColor(trump: trump) == led }
            if !canFollow || hand.count == 1 { return true }
        }
        return false
    }

    /// Effective money value of the cards already on the table, applying the
    /// Bull/Bear modifier present (mirrors `GameState.trickValue`). A trick
    /// currently Beared is worth 0; a Bull-doubled one is worth base×2. Shared
    /// with the agent shortlist so both reason about real worth, not raw money.
    static func tableValue(_ onTable: [PlayedCard]) -> Int {
        guard let first = onTable.first else { return 0 }
        return GameState.trickValue(Trick(leader: first.player, plays: onTable))
    }

    /// True when the last special on the table is a Bear — the trick is worth
    /// 0 right now and any money added to it is wasted (unless a later Bull
    /// flips it back, which is handled separately).
    static func tableIsBeared(_ onTable: [PlayedCard]) -> Bool {
        var last: Card? = nil
        for pc in onTable {
            switch pc.card {
            case .bull, .bear: last = pc.card
            default: break
            }
        }
        if case .bear = last { return true }
        return false
    }

    /// Highest money card in a pool, excluding Tiger.
    private static func highestMoneyDump(_ pool: [Card]) -> Card? {
        let money = pool.filter { $0.isMoney }
        guard !money.isEmpty else { return nil }
        return money.max { rankOf($0) < rankOf($1) }
    }

    /// "Lowest" = least costly to give up. Cheapest first:
    ///   • when `bullIsCostly` (we're feeding an opponent-controlled trick that
    ///     already holds money) the Bull is the LAST thing we'd shed — it would
    ///     double the opponents' take. The Bear stays cheap: it cancels.
    ///   • non-money before money,
    ///   • non-special before special,
    ///   • among money, the smallest denomination (don't overpay a lost trick),
    ///   • then lowest trick strength.
    private static func cheapestShed(_ cards: [Card],
                                     led: CardColor?,
                                     trump: CardColor,
                                     bullIsCostly: Bool = false) -> Card {
        cards.min { a, b in
            if bullIsCostly && a.isBull != b.isBull { return b.isBull }
            if a.isMoney != b.isMoney { return !a.isMoney }
            if a.isSpecial != b.isSpecial { return !a.isSpecial }
            if a.moneyValue != b.moneyValue { return a.moneyValue < b.moneyValue }
            return strength(a, led: led, trump: trump)
                 < strength(b, led: led, trump: trump)
        }!
    }

    // MARK: - Discard fallback

    private static func cheapestDiscard(_ moves: [Move]) -> Move {
        // Cheapest by (money $$, then rank). The engine already disallows
        // specials and unnecessary money discards.
        func cost(_ m: Move) -> Int {
            guard case .discardWidow(let cs) = m else { return .max }
            return cs.reduce(0) { $0 + $1.moneyValue * 1000 + rankOf($1) }
        }
        return moves.min { cost($0) < cost($1) } ?? moves[0]
    }

    // MARK: - Shared strength + helpers

    /// Mirrors GameState.trickWinner. Higher = stronger.
    static func strength(_ card: Card,
                         led: CardColor?,
                         trump: CardColor) -> Int {
        switch card {
        case .tiger: return 10_000
        case .colored(let c, let r):
            if c == trump { return 1_000 + r.rawValue }
            if let led, c == led { return 100 + r.rawValue }
            return -1
        case .bull, .bear: return -1
        }
    }

    static func rankOf(_ card: Card) -> Int {
        switch card {
        case .tiger: return 13
        case .colored(_, let r): return r.rawValue
        case .bull, .bear: return -1
        }
    }

    /// Per effective color, the highest card the seat holds. Used to
    /// identify "controllers" that should NOT be dumped onto a partner's
    /// safe trick (principle 8).
    static func topOfEachColorInHand(_ hand: [Card],
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

// MARK: - Tiny conveniences

private extension Card {
    /// The literal color (suit) of a colored card, irrespective of trump.
    /// nil for Tiger/Bull/Bear.
    var suitColor: CardColor? {
        if case .colored(let c, _) = self { return c }
        return nil
    }
}
