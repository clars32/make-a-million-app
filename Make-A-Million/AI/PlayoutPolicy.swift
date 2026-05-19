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
        let moneyOnTable = onTable.reduce(0) { $0 + $1.card.moneyValue }

        // Cards that, if played now, would take the trick.
        func wouldWin(_ c: Card) -> Bool {
            var t = onTable
            t.append(PlayedCard(player: seat, card: c))
            let w = GameState.trickWinner(
                Trick(leader: trick?.leader ?? seat, plays: t), trump: trump)
            return w == seat
        }

        if partnerWinning && moneyOnTable == 0 {
            // Partner has a worthless trick under control — dump the lowest.
            return .play(lowest(plays, led: led, trump: trump))
        }

        let winners = plays.filter(wouldWin)
        if !winners.isEmpty && (moneyOnTable > 0 || !partnerWinning) {
            // Take it as cheaply as possible.
            let c = winners.min { strength($0, led: led, trump: trump)
                                < strength($1, led: led, trump: trump) }!
            return .play(c)
        }

        // Can't or shouldn't win: shed the least valuable card.
        return .play(lowest(plays, led: led, trump: trump))
    }

    // MARK: Small heuristics

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
