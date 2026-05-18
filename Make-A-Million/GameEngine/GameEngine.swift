//
//  GameEngine.swift
//  Make-a-Million
//
//  The engine owns the ONLY true game state. Agents submit Moves and receive
//  redacted PlayerViews. `applying(_:)` is a pure function: (State, Move) ->
//  State, no side effects. The deal is seeded. Together that means any hand
//  is fully reconstructable from (seed, [moves]).
//

import Foundation

// MARK: - Phases

enum Phase: Codable, Hashable {
    case bidding
    case misdealDecision        // high bidder is misdeal-eligible, must call or decline
    case widowDiscard           // high bidder holds 13+3, must discard 3
    case namingTrump
    case trickPlay
    case handComplete
}

// MARK: - A trick in progress / completed

struct PlayedCard: Codable, Hashable {
    let player: PlayerID
    let card: Card
}

struct Trick: Codable, Hashable {
    let leader: PlayerID
    var plays: [PlayedCard] = []
    var isComplete: Bool { plays.count == Seats.count }

    /// Color led. The Bull/Bear can never legally lead in normal play (only
    /// as a last card), so the led color is the leader's card's effective
    /// color. In the rules' forced-Bull/Bear-lead corner the next card sets
    /// the color; we resolve that in `ledColor(trump:)`.
    func ledColor(trump: CardColor) -> CardColor? {
        for pc in plays {
            if let c = pc.card.effectiveColor(trump: trump) { return c }
        }
        return nil
    }
}

// MARK: - GameState  (the single source of truth)

struct GameState: Codable {

    // Dealing / identity
    let dealSeed: UInt64
    let dealer: PlayerID

    // Hidden truth: each seat's hand. Never leaves the engine except via the
    // redacted PlayerView projection.
    private(set) var hands: [PlayerID: [Card]]
    private(set) var widow: [Card]

    // Bidding
    private(set) var phase: Phase
    private(set) var toAct: PlayerID
    private(set) var highBid: Int?
    private(set) var highBidder: PlayerID?
    private(set) var passed: Set<PlayerID>

    // Hand setup
    private(set) var trump: CardColor?
    private(set) var misdealEligible: Bool

    // Trick play
    private(set) var currentTrick: Trick?
    private(set) var completedTricks: [Trick]
    /// Captured tricks grouped by capturing team (0 or 1), for scoring.
    private(set) var capturedByTeam: [Int: [Trick]]

    // Cumulative match score by team. First to 1,000,000 wins.
    private(set) var matchScore: [Int: Int]

    // MARK: Dealing

    /// Deal a fresh hand. 13 cards to each of 4 seats, 3 to the widow.
    /// Seeded shuffle → deterministic and reconstructable.
    static func newHand(dealer: PlayerID,
                        seed: UInt64,
                        carryScore: [Int: Int] = [0: 0, 1: 0]) -> GameState {
        var rng = SeededRNG(seed: seed)
        var deck = Deck.full
        // Fisher–Yates with the seeded RNG.
        for i in stride(from: deck.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            deck.swapAt(i, j)
        }

        var hands: [PlayerID: [Card]] = [:]
        for (idx, seat) in Seats.all.enumerated() {
            hands[seat] = Array(deck[(idx * 13)..<(idx * 13 + 13)])
        }
        let widow = Array(deck[52..<55])

        let opener = Seats.next(dealer)   // player left of dealer bids first

        // Misdeal eligibility: any player with $15,000 or less of Money in hand
        // may (later) call for a redeal. We flag it now; the social vote is
        // simplified for solo — the eligible player alone decides.
        let anyShort = hands.values.contains { hand in
            hand.reduce(0) { $0 + $1.moneyValue } <= 15_000
        }

        return GameState(
            dealSeed: seed,
            dealer: dealer,
            hands: hands,
            widow: widow,
            phase: .bidding,
            toAct: opener,
            highBid: nil,
            highBidder: nil,
            passed: [],
            trump: nil,
            misdealEligible: anyShort,
            currentTrick: nil,
            completedTricks: [],
            capturedByTeam: [0: [], 1: []],
            matchScore: carryScore
        )
    }
}

// MARK: - Errors

enum MoveError: Error, Equatable {
    case wrongPhase
    case notYourTurn
    case illegalBid
    case illegalDiscard
    case cardNotInHand
    case mustFollowColor
    case specialCardNotAllowed
    case noSuchMove
}

// MARK: - Legal moves

extension GameState {

    /// All legal moves for `player` in the current state. The UI binds to this
    /// (only show playable cards); the AI samples against it later.
    func legalMoves(for player: PlayerID) -> [Move] {
        guard player == toAct else { return [] }

        switch phase {
        case .bidding:
            var moves: [Move] = [.bid(.pass)]
            // Opening bid is exactly the minimum; raises step by the
            // increment above the standing high bid. A finite ladder up to
            // the max a hand can be worth keeps AI branching finite.
            var amount = (highBid == nil)
                ? Bidding.openingMinimum
                : highBid! + Bidding.raiseIncrement
            while amount <= 400_000 {
                moves.append(.bid(.bid(amount)))
                amount += Bidding.raiseIncrement
            }
            return moves

        case .misdealDecision:
            return [.callMisdeal, .declineMisdeal]

        case .widowDiscard:
            // Any 3-card discard that obeys the Money / special restrictions.
            // Enumerating all C(16,3) combinations is fine (560 max) and lets
            // the UI/AI see exactly what's legal.
            guard let hand = hands[player] else { return [] }
            var moves: [Move] = []
            let combos = Self.combinations(hand, choose: 3)
            for combo in combos where Self.isLegalWidowDiscard(combo, from: hand) {
                moves.append(.discardWidow(combo))
            }
            return moves

        case .namingTrump:
            return CardColor.allCases.map { .nameTrump($0) }

        case .trickPlay:
            guard let hand = hands[player] else { return [] }
            return playableCards(from: hand).map { .play($0) }

        case .handComplete:
            return []
        }
    }

    /// Cards `player` may legally play to the current trick given their hand.
    private func playableCards(from hand: [Card]) -> [Card] {
        guard let trump = trump else { return [] }
        let isLeading = (currentTrick?.plays.isEmpty ?? true)

        if isLeading {
            // Bull/Bear may never be LED while the player still holds any
            // other card. The escape hatch is "no leadable alternative" —
            // i.e. the remaining hand is entirely Bull/Bear, which at the
            // very end of a hand can be ONE OR TWO cards. The earlier
            // `hand.count == 1` form missed the two-specials endgame and
            // produced a state with no legal move. The Tiger is freely
            // leadable (it just calls trumps); only Bull/Bear are restricted.
            let leadable = hand.filter { card in
                switch card {
                case .bull, .bear: return false
                case .tiger, .colored: return true
                }
            }
            return leadable.isEmpty ? hand : leadable
        }

        // Following. Determine the led color.
        guard let trick = currentTrick,
              let led = trick.ledColor(trump: trump) else { return hand }

        let canFollow = hand.contains { $0.effectiveColor(trump: trump) == led }

        if canFollow {
            // Must follow color. Bull/Bear are NOT of the led color, so they
            // are excluded here automatically; the Tiger counts as trump's
            // color and is only legal here if trump == led.
            return hand.filter { $0.effectiveColor(trump: trump) == led }
        } else {
            // Cannot follow: free choice — any card, including trump, Tiger,
            // Bull, Bear, or a Money card "if he thinks his partner takes it".
            return hand
        }
    }

    static func isLegalWidowDiscard(_ discard: [Card], from hand: [Card]) -> Bool {
        guard discard.count == 3 else { return false }
        // Never discard Tiger / Bull / Bear.
        if discard.contains(where: { $0.isSpecial }) { return false }
        // Must not discard a Money card unless there is no non-Money,
        // non-special alternative. (If forced, the rules require showing them;
        // that disclosure is a UI concern, legality is enforced here.)
        let nonMoneyNonSpecial = hand.filter { !$0.isMoney && !$0.isSpecial }
        for card in discard where card.isMoney {
            // A Money discard is only legal if we couldn't have filled that
            // slot from the non-Money pool.
            if nonMoneyNonSpecial.count >= 3 { return false }
        }
        return true
    }

    static func combinations<T>(_ arr: [T], choose k: Int) -> [[T]] {
        guard k > 0 else { return [[]] }
        guard arr.count >= k else { return [] }
        if arr.count == k { return [arr] }
        var result: [[T]] = []
        func recurse(_ start: Int, _ pick: [T]) {
            if pick.count == k { result.append(pick); return }
            for i in start..<arr.count {
                recurse(i + 1, pick + [arr[i]])
            }
        }
        recurse(0, [])
        return result
    }
}

// MARK: - The reducer:  (State, Move) -> State, pure

extension GameState {

    func applying(_ move: Move, by player: PlayerID) throws -> GameState {
        guard player == toAct else { throw MoveError.notYourTurn }
        var s = self

        switch (phase, move) {

        // MARK: Bidding
        case (.bidding, .bid(let action)):
            try s.applyBid(action, by: player)
            return s

        // MARK: Misdeal decision
        case (.misdealDecision, .callMisdeal):
            // Redeal: same dealer, next seed derived deterministically.
            return GameState.newHand(dealer: s.dealer,
                                     seed: s.dealSeed &+ 1,
                                     carryScore: s.matchScore)

        case (.misdealDecision, .declineMisdeal):
            s.phase = .widowDiscard
            s.toAct = s.highBidder!
            s.takeWidowIntoHand()
            return s

        // MARK: Widow discard
        case (.widowDiscard, .discardWidow(let cards)):
            guard let hand = s.hands[player],
                  Set(cards).count == 3,
                  cards.allSatisfy({ hand.contains($0) }),
                  GameState.isLegalWidowDiscard(cards, from: hand)
            else { throw MoveError.illegalDiscard }
            s.hands[player] = hand.filter { !cards.contains($0) }
            s.phase = .namingTrump
            return s

        // MARK: Naming trump
        case (.namingTrump, .nameTrump(let color)):
            s.trump = color
            s.phase = .trickPlay
            s.toAct = s.highBidder!          // high bidder leads first trick
            s.currentTrick = Trick(leader: s.highBidder!)
            return s

        // MARK: Trick play
        case (.trickPlay, .play(let card)):
            try s.applyPlay(card, by: player)
            return s

        default:
            throw MoveError.wrongPhase
        }
    }

    // MARK: Bidding logic

    private mutating func applyBid(_ action: BidAction, by player: PlayerID) throws {
        switch action {
        case .pass:
            passed.insert(player)
        case .bid(let amount):
            if highBid == nil {
                // Opening bid: at least the opening minimum, on the raise grid
                // *relative to that minimum*. $175,000 itself is legal even
                // though it is not a multiple of $10,000.
                guard amount >= Bidding.openingMinimum,
                      (amount - Bidding.openingMinimum) % Bidding.raiseIncrement == 0
                else { throw MoveError.illegalBid }
            } else {
                // A raise: at least one increment above the standing high bid.
                guard amount >= highBid! + Bidding.raiseIncrement,
                      (amount - Bidding.openingMinimum) % Bidding.raiseIncrement == 0
                else { throw MoveError.illegalBid }
            }
            highBid = amount
            highBidder = player
        }

        // Bidding ends when everyone except one has passed AND there is a bid.
        if let bidder = highBidder, passed.count == Seats.count - 1 {
            highBidder = bidder
            if misdealEligible {
                phase = .misdealDecision
                toAct = bidder              // high bidder decides on misdeal
            } else {
                phase = .widowDiscard
                toAct = bidder
                takeWidowIntoHand()
            }
            return
        }

        // No one bid and three passed: degenerate. Force opener to hold the
        // minimum bid rather than deadlock. (Rare with a 55-card deal; the
        // misdeal rule usually catches the bad hands first.)
        if highBidder == nil && passed.count == Seats.count - 1 {
            let opener = Seats.next(dealer)
            highBid = Bidding.openingMinimum
            highBidder = opener
            phase = misdealEligible ? .misdealDecision : .widowDiscard
            toAct = opener
            if !misdealEligible { takeWidowIntoHand() }
            return
        }

        advanceBidder()
    }

    private mutating func advanceBidder() {
        var n = Seats.next(toAct)
        while passed.contains(n) { n = Seats.next(n) }
        toAct = n
    }

    private mutating func takeWidowIntoHand() {
        guard let b = highBidder else { return }
        hands[b, default: []].append(contentsOf: widow)
        widow = []
    }

    // MARK: Trick logic

    private mutating func applyPlay(_ card: Card, by player: PlayerID) throws {
        guard var hand = hands[player] else { throw MoveError.cardNotInHand }
        guard hand.contains(card) else { throw MoveError.cardNotInHand }
        guard playableCards(from: hand).contains(card) else {
            // Distinguish the two common illegal cases for better errors.
            if card.isSpecial { throw MoveError.specialCardNotAllowed }
            throw MoveError.mustFollowColor
        }

        hand.removeAll { $0 == card }
        hands[player] = hand

        if currentTrick == nil { currentTrick = Trick(leader: player) }
        currentTrick!.plays.append(PlayedCard(player: player, card: card))

        if currentTrick!.isComplete {
            let winner = GameState.trickWinner(currentTrick!, trump: trump!)
            let team = Seats.team(of: winner)
            completedTricks.append(currentTrick!)
            capturedByTeam[team, default: []].append(currentTrick!)

            if hands.values.allSatisfy({ $0.isEmpty }) {
                phase = .handComplete
                settleHand()
                currentTrick = nil
            } else {
                currentTrick = Trick(leader: winner)   // winner leads next
                toAct = winner
            }
        } else {
            toAct = Seats.next(player)
        }
    }

    /// The winner of a completed trick. Bull/Bear can NEVER win (confirmed
    /// rule) — they only modify value at scoring time. Highest card of the
    /// led color wins, unless any trump was played, in which case the highest
    /// trump wins. The Tiger is the top trump.
    static func trickWinner(_ trick: Trick, trump: CardColor) -> PlayerID {
        let led = trick.ledColor(trump: trump)

        func strength(_ card: Card) -> Int {
            switch card {
            case .tiger:
                return 10_000                       // top trump, beats all
            case .colored(let c, let r):
                if c == trump { return 1_000 + r.rawValue }       // any trump
                if c == led   { return 100 + r.rawValue }         // led color
                return -1                                          // off, can't win
            case .bull, .bear:
                return -1                                          // never wins
            }
        }

        var best = trick.plays[0]
        for pc in trick.plays.dropFirst() {
            if strength(pc.card) > strength(best.card) { best = pc }
        }
        return best.player
    }

    // MARK: Scoring

    /// Value of one captured trick: sum of Money cards, then Bull doubles /
    /// Bear cancels. If BOTH appear in the trick, only the one played LAST
    /// takes effect (confirmed rule).
    static func trickValue(_ trick: Trick) -> Int {
        let base = trick.plays.reduce(0) { $0 + $1.card.moneyValue }
        var lastModifier: Card? = nil
        for pc in trick.plays {
            if case .bull = pc.card { lastModifier = .bull }
            if case .bear = pc.card { lastModifier = .bear }
        }
        switch lastModifier {
        case .bull: return base * 2
        case .bear: return 0
        default:    return base
        }
    }

    private mutating func settleHand() {
        let t0 = (capturedByTeam[0] ?? []).reduce(0) { $0 + GameState.trickValue($1) }
        let t1 = (capturedByTeam[1] ?? []).reduce(0) { $0 + GameState.trickValue($1) }

        guard let bidder = highBidder, let bid = highBid else { return }
        let bidTeam = Seats.team(of: bidder)
        let bidTeamCount  = bidTeam == 0 ? t0 : t1
        let otherTeam     = 1 - bidTeam
        let otherCount    = bidTeam == 0 ? t1 : t0

        if bidTeamCount >= bid {
            matchScore[bidTeam, default: 0] += bidTeamCount
        } else {
            matchScore[bidTeam, default: 0] -= bid      // set back the full bid
        }
        // The non-bidding side always keeps what it captured.
        matchScore[otherTeam, default: 0] += otherCount
    }

    /// Final result once `phase == .handComplete`. nil if the match continues.
    var matchWinner: Int? {
        guard phase == .handComplete else { return nil }
        let s0 = matchScore[0] ?? 0
        let s1 = matchScore[1] ?? 0
        guard s0 >= 1_000_000 || s1 >= 1_000_000 else { return nil }
        return s0 >= s1 ? 0 : 1     // ties on/over a million: higher wins
    }
}

// MARK: - Redacted PlayerView (the ONLY thing that crosses the UI/AI boundary)

/// One completed trick as PUBLIC knowledge: what every seat played and who
/// took it. This is not hidden information — at a physical table everyone
/// watches each trick being taken — so surfacing it in the redacted view
/// leaks nothing. The AI will also need this to reason about what has been
/// played; same projection, no privileged access.
struct CompletedTrickInfo: Codable, Hashable {
    let leader: PlayerID
    let plays: [PlayedCard]
    let winner: PlayerID
    let value: Int          // settled $ value of the trick (Bull/Bear applied)
}

struct PlayerView: Codable {
    let me: PlayerID
    let myHand: [Card]
    let phase: Phase
    let toAct: PlayerID
    let trump: CardColor?
    let highBid: Int?
    let highBidder: PlayerID?
    let passed: [PlayerID]
    let currentTrick: Trick?
    let completedTrickCount: Int
    /// Full public trick history, oldest first. Empty until the first trick
    /// completes. The most recent entry is "what just happened".
    let completedTricks: [CompletedTrickInfo]
    let matchScore: [Int: Int]
    let legalMoves: [Move]

    /// Convenience: the trick that just resolved, if any.
    var lastTrick: CompletedTrickInfo? { completedTricks.last }
}

extension GameState {
    /// Project the full truth down to what one seat is allowed to know:
    /// own hand + public history. The widow and other hands never appear.
    /// The Monte Carlo AI later samples full deals consistent with exactly
    /// this — same projection, no privileged access.
    func view(for player: PlayerID) -> PlayerView {
        // Reconstruct public trick history. trump is known once set; before
        // that no tricks exist, so the force-unwrap is safe in context.
        let history: [CompletedTrickInfo] = completedTricks.map { tr in
            let w = GameState.trickWinner(tr, trump: trump ?? .red)
            return CompletedTrickInfo(
                leader: tr.leader,
                plays: tr.plays,
                winner: w,
                value: GameState.trickValue(tr))
        }
        return PlayerView(
            me: player,
            myHand: hands[player] ?? [],
            phase: phase,
            toAct: toAct,
            trump: trump,
            highBid: highBid,
            highBidder: highBidder,
            passed: Array(passed),
            currentTrick: currentTrick,
            completedTrickCount: completedTricks.count,
            completedTricks: history,
            matchScore: matchScore,
            legalMoves: legalMoves(for: player)
        )
    }
}
