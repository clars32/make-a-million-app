//
//  PlayoutPolicy.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/20/26.
//


//
//  PlayoutPolicy.swift
//  Make-a-Million
//
//  A fast, deterministic, rule-respecting policy used to roll a determinized
//  world forward to handComplete. It is NOT the AI's real decision procedure
//  — it is the cheap "what would roughly happen next" simulator the Monte
//  Carlo agent calls thousands of times.
//
//  Why not random rollouts: in trick-taking games with hidden information,
//  uniform-random playouts are famously weak — they wash out exactly the
//  tactical signal (who can win this trick, is my partner already winning,
//  is there money on the table) that the evaluation needs. A small amount of
//  sane heuristic here is worth far more than more samples of noise. This is
//  the first and most important tuning surface.
//
//  It chooses ONLY from the engine's own legalMoves, so it can never produce
//  an illegal move and never duplicates a rule.
//
//  ENGINE BINDING: GameState.legalMoves(for:) / .currentTrick / .trump /
//  .highBidder ; GameState.trickWinner(_:trump:) ; Card.effectiveColor /
//  .isSpecial / .isMoney ; Seats.team(of:) ; Move cases.
//

import Foundation

enum PlayoutPolicy {

    /// Choose a move for `seat` in `state`. Total: always returns a legal
    /// move (engine guarantees a non-empty set on turn).
    static func move(in state: GameState, seat: PlayerID) -> Move {
        let moves = state.legalMoves(for: seat)
        precondition(!moves.isEmpty,
                     "PlayoutPolicy asked to move with no legal moves — "
                     + "engine invariant violated (called at \(state.phase)?)")
        if moves.count == 1 { return moves[0] }

        switch state.phase {
        case .bidding:
            // Determinized worlds are constructed at/after the declarer is
            // known, so rollouts effectively never bid. Pass keeps the loop
            // total if one ever does.
            return moves.first { $0.isPass } ?? moves[0]

        case .misdealDecision:
            return .declineMisdeal

        case .widowDiscard:
            return cheapestDiscard(moves)

        case .namingTrump:
            // Dead in normal play: every real trump choice is made by
            // MonteCarloAgent (which evaluates all four colors), never by a
            // rollout — bidding and discard both name trump *before* rolling
            // out. This is only a safety fallback so the policy stays total.
            return moves[0]

        case .trickPlay:
            return trickMove(in: state, seat: seat, legal: moves)

        case .handComplete:
            return moves[0]                                  // unreachable
        }
    }

    // MARK: Trick play — the part that actually matters

    private static func trickMove(in state: GameState,
                                  seat: PlayerID,
                                  legal: [Move]) -> Move {
        guard let trump = state.trump else { return legal[0] }
        let plays = legal.compactMap { $0.playedCard }
        guard !plays.isEmpty else { return legal[0] }

        let trick = state.currentTrick
        let onTable = trick?.plays ?? []

        // Leading: lead a low non-special card; hang onto money and trump.
        if onTable.isEmpty {
            let nonSpecial = plays.filter { !$0.isSpecial && !$0.isMoney }
            let pickFrom = nonSpecial.isEmpty ? plays : nonSpecial
            let c = pickFrom.min { strength($0, led: nil, trump: trump)
                                 < strength($1, led: nil, trump: trump) }!
            return .play(c)
        }

        // Following / discarding. Work out who is currently winning.
        let led = trick?.ledColor(trump: trump)
        let provisional = Trick(leader: trick?.leader ?? seat, plays: onTable)
        let currentWinner = GameState.trickWinner(provisional, trump: trump)
        let partnerWinning = Seats.team(of: currentWinner) == Seats.team(of: seat)

        // EFFECTIVE money on the trick, with Bull/Bear applied. A
        // Bear-locked trick is worth $0 no matter how much money is
        // stacked on it, so the "defend partner's winning trick" branch
        // below should treat it as worthless and shed junk instead of
        // piling cash onto a trick that scores zero anyway. This is the
        // root of the Bear-on-table bug.
        let effectiveMoneyOnTable = currentEffectiveMoney(on: onTable)

        // Seats that still play AFTER me in this trick. Cards I commit can
        // be topped by any of these. We treat THEIR sampled hands as truth
        // for this determinized world — the MC layer averages over many
        // samples, so reading state.hands here is the right move, not a
        // peek at hidden information.
        let playedSeats = Set(onTable.map(\.player))
        let remainingSeats = Seats.all.filter { $0 != seat && !playedSeats.contains($0) }
        let remainingOpponents = remainingSeats.filter {
            Seats.team(of: $0) != Seats.team(of: seat)
        }

        // Cards that, if played now, would take the trick.
        func wouldWin(_ c: Card) -> Bool {
            var t = onTable
            t.append(PlayedCard(player: seat, card: c))
            let w = GameState.trickWinner(
                Trick(leader: trick?.leader ?? seat, plays: t), trump: trump)
            return w == seat
        }

        // True if any remaining opponent holds a card that beats `c` in
        // this trick's strength order. The "$30k into $40k" bug is exactly
        // this: $30k wouldWin() right now, but $40k is in an opponent's
        // sampled hand and will arrive later.
        func couldBeTopped(_ c: Card) -> Bool {
            let myStr = strength(c, led: led, trump: trump)
            for opp in remainingOpponents {
                guard let hand = state.hands[opp] else { continue }
                for other in hand where strength(other, led: led, trump: trump) > myStr {
                    return true
                }
            }
            return false
        }

        if partnerWinning && effectiveMoneyOnTable == 0 {
            // Partner has a trick that's currently worth nothing — empty
            // of money OR Bear-locked. Dump the lowest card; don't add
            // money that's about to score zero.
            return .play(lowest(plays, led: led, trump: trump))
        }

        let allWinners = plays.filter(wouldWin)

        // Money cards count as winners only if they can't still be
        // beaten by a remaining opponent. Non-money winners are kept
        // unconditionally: even if they get topped we've lost a low
        // card, not a money card.
        let winners = allWinners.filter { c in
            if !c.isMoney { return true }
            return !couldBeTopped(c)
        }

        if !winners.isEmpty && (effectiveMoneyOnTable > 0 || !partnerWinning) {
            // Take it as cheaply as possible, BUT prefer a non-money winner
            // when one exists. Without this preference, raw `strength` sort
            // picks $5k (rank 4) over a 7 (rank 5) — committing money for
            // no extra capturing power.
            let nonMoneyWinners = winners.filter { !$0.isMoney }
            let pool = nonMoneyWinners.isEmpty ? winners : nonMoneyWinners
            let c = pool.min { strength($0, led: led, trump: trump)
                             < strength($1, led: led, trump: trump) }!
            return .play(c)
        }

        // Can't or shouldn't win: shed the least valuable card.
        return .play(lowest(plays, led: led, trump: trump))
    }

    // MARK: Small heuristics

    /// Effective money currently on the trick, with Bull/Bear modifiers
    /// applied to what is on the table NOW. Mirrors GameState.trickValue
    /// for the partial-trick case. The "last modifier wins" rule applies
    /// even mid-trick — if Bear is the most recent of Bull/Bear played,
    /// the trick is worth zero until/unless Bull arrives later. Future
    /// Bull/Bear plays are accounted for by the rollout itself, not by
    /// this snapshot.
    private static func currentEffectiveMoney(on plays: [PlayedCard]) -> Int {
        let base = plays.reduce(0) { $0 + $1.card.moneyValue }
        var lastModifier: Card? = nil
        for pc in plays {
            if case .bull = pc.card { lastModifier = .bull }
            if case .bear = pc.card { lastModifier = .bear }
        }
        switch lastModifier {
        case .bull: return base * 2
        case .bear: return 0
        default:    return base
        }
    }

    /// Mirrors the engine's trick-winner strength scheme so the policy's
    /// notion of "high/low" matches who actually wins. This is the only
    /// place the AI echoes winner logic, and only for ordering — never for
    /// legality, which always comes from the engine.
    private static func strength(_ card: Card,
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

    /// "Lowest" = least costly to give up: non-money before money, low
    /// strength before high.
    private static func lowest(_ cards: [Card],
                               led: CardColor?,
                               trump: CardColor) -> Card {
        cards.min { a, b in
            if a.isMoney != b.isMoney { return !a.isMoney }
            return strength(a, led: led, trump: trump)
                 < strength(b, led: led, trump: trump)
        }!
    }

    private static func cheapestDiscard(_ moves: [Move]) -> Move {
        // Legality already forbids needless money discards; among the legal
        // 3-card discards, drop the one carrying the least money / lowest
        // ranks.
        func cost(_ m: Move) -> Int {
            guard case .discardWidow(let cs) = m else { return .max }
            return cs.reduce(0) { $0 + $1.moneyValue * 1000 + rankValue($1) }
        }
        return moves.min { cost($0) < cost($1) } ?? moves[0]
    }

    private static func rankValue(_ c: Card) -> Int {
        if case .colored(_, let r) = c { return r.rawValue }
        return 0
    }
}