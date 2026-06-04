//
//  TableInference.swift
//  Make-a-Million
//
//  A view-side wrapper that condenses everything PUBLIC about the table
//  into the things a strong human player actually uses:
//
//    • What's been played so far (per color, per player).
//    • Which players have shown themselves void in which colors.
//    • The single highest card still unaccounted for, per color.
//    • How much trump has been pulled out of opponent hands.
//    • Whether a color has been led yet (the "$40k first time" rule).
//
//  The point is to put this in ONE place, computed once per decision,
//  rather than re-deriving it inside every tactical heuristic. The
//  Determinizer does its own void inference for sampling worlds; this
//  one is for the heuristic layer that reads tactics directly.
//
//  No private info crosses this boundary. It is built strictly from a
//  PlayerView — the same redacted projection every agent gets — and
//  treats the visible widow exactly as a human treats it: as cards the
//  declarer has SEEN, three of which they have since discarded (which
//  we cannot identify), the rest of which are now in their hand.
//
//  ENGINE BINDING: PlayerView.{me, myHand, trump, widow, currentTrick,
//  completedTricks, highBidder} ; CompletedTrickInfo.{leader, plays,
//  winner} ; PlayedCard.{player, card} ; Card.{effectiveColor, isMoney,
//  isSpecial, moneyValue} ; CardColor.allCases ; Seats.{all, partner,
//  team, next, count} ; Deck.full.
//

import Foundation

struct TableInference {

    // MARK: - Public projection

    let me: PlayerID
    let myHand: [Card]
    let trump: CardColor?
    /// True if we've completed the bidding phase (so trump is known and
    /// the widow has been picked up). Card-counting only matters from
    /// here on.
    let inTrickPlay: Bool

    /// Effective-color → cards still unaccounted for AT OPPONENTS / partner
    /// (i.e. not in my hand, not on the table, not in tricks already
    /// completed). Widow cards in the declarer's hand show up here too —
    /// because they might still be played.
    private let stillOut: [CardColor: Set<Card>]
    /// Widow cards that CANNOT have been discarded (Tiger / Bull / Bear /
    /// money — the engine forbids discarding any of these). These are
    /// guaranteed to be in the declarer's hand right now, if not yet
    /// played. Principle 11: "remember what was in the widow."
    private let knownWidowInDeclarer: Set<Card>
    /// Who took the widow (declarer). nil before bidding settled.
    private let declarer: PlayerID?
    /// The Tiger / Bull / Bear if they have not yet been played.
    private let tigerLoose: Bool
    private let bullLoose: Bool
    private let bearLoose: Bool

    /// Inferred voids: seat → set of colors that seat provably cannot follow.
    private let voids: [PlayerID: Set<CardColor>]

    /// Whether each color has been LED at least once during the hand.
    private let ledColors: Set<CardColor>

    /// How many cards in each color have been played in total.
    private let playedCountByColor: [CardColor: Int]

    /// Trump cards that have been seen (played + in my hand) — the
    /// complement is how much trump is still out among the other three.
    private let trumpRemainingOut: Int

    // MARK: - Build

    init(view: PlayerView) {
        self.me = view.me
        self.myHand = view.myHand
        self.trump = view.trump
        self.inTrickPlay = (view.trump != nil)

        // 1. Collect every card we've seen play out.
        var played: [Card] = []
        var playedByColor: [CardColor: Int] = [:]
        var led: Set<CardColor> = []

        // Completed tricks.
        for info in view.completedTricks {
            for pc in info.plays { played.append(pc.card) }
            if let t = view.trump,
               let lc = pc_ledColor(info.plays, trump: t) {
                led.insert(lc)
            }
        }
        // Trick in progress.
        if let cur = view.currentTrick {
            for pc in cur.plays { played.append(pc.card) }
            if let t = view.trump,
               let lc = pc_ledColor(cur.plays, trump: t) {
                led.insert(lc)
            }
        }

        // Tally by effective color (using trump if known; else raw color
        // — the led-color tracking below ignores pre-trump-play anyway).
        for card in played {
            let ec = card.effectiveColor(trump: view.trump ?? .red)
            if let c = ec {
                playedByColor[c, default: 0] += 1
            }
        }
        self.playedCountByColor = playedByColor
        self.ledColors = led

        // 2. Compute stillOut by subtracting (myHand + played + discarded
        //    widow cards if we know them) from the full deck.
        //
        //    Widow handling: cards in PlayerView.widow are the THREE cards
        //    dealt to the widow at deal time, made public when the bidding
        //    settled. The declarer has since discarded three. Without
        //    knowing which three were discarded, we conservatively treat
        //    the widow cards as still potentially in the declarer's hand —
        //    they SHOW UP in `stillOut` and so a "highest card outstanding"
        //    calculation correctly worries about them.
        //
        //    Exception: I AM the declarer. Then my current `myHand`
        //    already accounts for what I kept (and what I discarded), so
        //    nothing further is needed.
        var pool = Set(Deck.full)
        pool.subtract(myHand)
        pool.subtract(played)
        // If I'm not the declarer, leave widow cards in the pool — they
        // might be in declarer's hand.
        if let widow = view.widow, view.highBidder == view.me {
            // I'm declarer — I know my own hand including kept widow cards
            // (they're already in myHand). The widow array does NOT have
            // the discarded cards subtracted from it, so we can't pinpoint
            // them. Leave widow cards in the pool unless they're in myHand.
            _ = widow   // intentionally unused: we can't recover discards
        }

        // 3. Special tracking.
        self.tigerLoose = pool.contains(.tiger)
        self.bullLoose  = pool.contains(.bull)
        self.bearLoose  = pool.contains(.bear)

        // 4. Bucket stillOut by effective color (trump-aware).
        var bucket: [CardColor: Set<Card>] = [:]
        for c in CardColor.allCases { bucket[c] = [] }
        for card in pool {
            if let ec = card.effectiveColor(trump: view.trump ?? .red) {
                bucket[ec, default: []].insert(card)
            }
            // Bull/Bear have no effective color — handled separately.
        }
        self.stillOut = bucket

        // 4b. Widow knowledge (principle 11). The engine forbids
        //     discarding Tiger / Bull / Bear / money cards from the widow,
        //     so any of those that appear in the publicly revealed widow
        //     are GUARANTEED to be in the declarer's hand right now —
        //     unless we've since seen them played.
        var widowLocked: Set<Card> = []
        if let widow = view.widow {
            let played = Set(view.completedTricks.flatMap { $0.plays.map(\.card) })
            let inProgress = Set(view.currentTrick?.plays.map(\.card) ?? [])
            for card in widow {
                let undiscardable = card.isSpecial || card.isMoney
                if undiscardable && !played.contains(card) && !inProgress.contains(card) {
                    // The declarer must still hold it (or have just played
                    // it in the current trick — handled by inProgress).
                    widowLocked.insert(card)
                }
            }
        }
        self.knownWidowInDeclarer = widowLocked
        self.declarer = view.highBidder

        // 5. Trump remaining.
        if let t = view.trump {
            self.trumpRemainingOut = bucket[t]?.count ?? 0
        } else {
            self.trumpRemainingOut = 0
        }

        // 6. Void inference: scan all completed tricks + the trick in
        //    progress. Anyone who failed to follow the led color is void
        //    in it. (Playing Bull/Bear is the engine's signal that the
        //    player COULDN'T follow — those imply a void too.)
        var voids: [PlayerID: Set<CardColor>] = [:]
        if let t = view.trump {
            func scan(_ leader: PlayerID, _ plays: [PlayedCard]) {
                guard let led = pc_ledColor(plays, trump: t) else { return }
                for pc in plays where pc.player != leader {
                    let ec = pc.card.effectiveColor(trump: t)
                    if ec != led {
                        voids[pc.player, default: []].insert(led)
                    }
                }
            }
            for info in view.completedTricks { scan(info.leader, info.plays) }
            if let cur = view.currentTrick { scan(cur.leader, cur.plays) }
        }
        self.voids = voids
    }

    // MARK: - Queries

    /// Has this color been LED yet this hand?
    func hasBeenLed(_ color: CardColor) -> Bool { ledColors.contains(color) }

    /// Has any seat shown a void in this color?
    func isKnownVoid(_ player: PlayerID, in color: CardColor) -> Bool {
        voids[player]?.contains(color) ?? false
    }

    /// The highest-ranking card of a color that is still in someone else's
    /// hand (or the widow). Returns nil if none.
    ///
    /// "Highest" here means the strongest trick-taker of that color: top
    /// trump = Tiger (when color == trump), then $40k, $30k, $15k, 11,
    /// $10k, 9, 8, 7, $5k, 4, 3, 2, 1.
    func highestOutInColor(_ color: CardColor) -> Card? {
        let pool = stillOut[color] ?? []
        if pool.isEmpty { return nil }
        return pool.max { rankValueForColorWin($0, color: color)
                        < rankValueForColorWin($1, color: color) }
    }

    /// True if my card is the highest of its color anyone might still play.
    /// "Of its color" follows the trick-resolution rules — Tiger counts
    /// as trump, Bull/Bear can never win.
    func iControlColor(_ card: Card) -> Bool {
        guard let t = trump else { return false }
        guard let ec = card.effectiveColor(trump: t) else { return false }
        guard let topOut = highestOutInColor(ec) else { return true }
        return rankValueForColorWin(card, color: ec)
             > rankValueForColorWin(topOut, color: ec)
    }

    /// Could the led color be trumped by someone who hasn't played yet?
    /// "Someone" = any seat that (a) hasn't played to the current trick
    /// AND (b) is provably void in the led color (or, if `pessimistic`,
    /// merely *could* be short — we assume the worst).
    func canBeTrumpedByRemainingPlayers(led: CardColor,
                                        currentTrick: Trick?,
                                        pessimistic: Bool = false) -> Bool {
        guard let t = trump, t != led else { return false }
        guard trumpRemainingOut > 0 || tigerLoose else { return false }
        guard let trick = currentTrick else { return false }
        let played = Set(trick.plays.map(\.player))
        for seat in Seats.all where !played.contains(seat) && seat != me {
            if isKnownVoid(seat, in: led) { return true }
            if pessimistic { return true }
        }
        return false
    }

    /// True if the Tiger is still unaccounted for.
    var isTigerOut: Bool { tigerLoose }
    var isBullOut: Bool { bullLoose }
    var isBearOut: Bool { bearLoose }

    /// Could a yet-to-play OPPONENT legally drop the loose Bear into this
    /// trick (zeroing its money)? Conservative — requires the Bear to be
    /// unaccounted for AND an opponent who has not yet played AND is provably
    /// void in the led color (so the engine would let them play a special).
    /// Used to avoid dumping our money onto a trick about to be cancelled.
    func opponentCanBearTrick(led: CardColor?, currentTrick: Trick?) -> Bool {
        guard bearLoose, let led = led, let trick = currentTrick else { return false }
        let played = Set(trick.plays.map(\.player))
        for s in Seats.all where !played.contains(s) && s != me {
            guard Seats.team(of: s) != Seats.team(of: me) else { continue }
            if isKnownVoid(s, in: led) { return true }
        }
        return false
    }

    /// Symmetric check for the loose Bull, which DOUBLES the captured money.
    func opponentCanBullTrick(led: CardColor?, currentTrick: Trick?) -> Bool {
        guard bullLoose, let led = led, let trick = currentTrick else { return false }
        let played = Set(trick.plays.map(\.player))
        for s in Seats.all where !played.contains(s) && s != me {
            guard Seats.team(of: s) != Seats.team(of: me) else { continue }
            if isKnownVoid(s, in: led) { return true }
        }
        return false
    }

    /// Cards from the widow that we KNOW the declarer must still hold
    /// (Tiger / Bull / Bear / money — the engine forbade discarding them).
    /// Principle 11. Empty if pre-trick-play or if all such cards have
    /// since been played.
    func knownDeclarerHoldings() -> Set<Card> { knownWidowInDeclarer }

    /// True if `card` is guaranteed to be in `seat`'s hand right now,
    /// based on widow-discard rules. Conservative: returns false unless
    /// we are sure.
    func isCardKnownIn(_ seat: PlayerID, card: Card) -> Bool {
        guard let d = declarer, seat == d else { return false }
        return knownWidowInDeclarer.contains(card)
    }

    /// How much trump is still out among the other three seats (counts the
    /// Tiger if it has not been played).
    var trumpStillOutInOpponentsAndPartner: Int {
        // stillOut[trump] already includes the Tiger (Tiger.effectiveColor
        // == trump). So trumpRemainingOut is correct, but minus any trump
        // I'm still holding. Easier: directly recompute from stillOut[trump]
        // minus my own trump cards.
        guard let t = trump else { return 0 }
        let pool = stillOut[t] ?? []
        let mine = Set(myHand.filter { $0.effectiveColor(trump: t) == t })
        return pool.subtracting(mine).count
    }

    /// My cards of a given effective color.
    func myCardsOf(_ color: CardColor) -> [Card] {
        guard let t = trump else { return [] }
        return myHand.filter { $0.effectiveColor(trump: t) == color }
    }

    // MARK: - Trick reading

    /// Who is currently winning the trick in progress? nil if no plays yet
    /// or no trump set.
    func currentWinner(in trick: Trick) -> PlayerID? {
        guard let t = trump, !trick.plays.isEmpty else { return nil }
        return GameState.trickWinner(trick, trump: t)
    }

    /// Is my partner currently winning this trick?
    func partnerWinning(in trick: Trick) -> Bool {
        guard let w = currentWinner(in: trick) else { return false }
        return Seats.team(of: w) == Seats.team(of: me) && w != me
    }

    /// Total money already played to this trick.
    func moneyOnTable(in trick: Trick) -> Int {
        trick.plays.reduce(0) { $0 + $1.card.moneyValue }
    }

    /// True if I am the last seat to play to this trick (third following
    /// player after the lead, so plays.count == Seats.count - 1).
    func iAmLastToPlay(in trick: Trick) -> Bool {
        trick.plays.count == Seats.count - 1
    }
}

// MARK: - Free helpers (file-private)

/// Same logic as Trick.ledColor(trump:) but pulled out so we can use it on
/// raw [PlayedCard] arrays from CompletedTrickInfo.
private func pc_ledColor(_ plays: [PlayedCard], trump: CardColor) -> CardColor? {
    for pc in plays {
        if let c = pc.card.effectiveColor(trump: trump) { return c }
    }
    return nil
}

/// Strength scheme that mirrors GameState.trickWinner. Used for ordering
/// — never for legality (which always goes through the engine).
fileprivate func rankValueForColorWin(_ card: Card, color: CardColor) -> Int {
    switch card {
    case .tiger:
        return 10_000
    case .colored(let c, let r):
        if c == color { return 1_000 + r.rawValue }
        return -1
    case .bull, .bear:
        return -1
    }
}
