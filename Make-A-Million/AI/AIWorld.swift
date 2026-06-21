//
//  AIWorld.swift
//  Make-a-Million
//
//  THE KEYSTONE of the Monte Carlo AI: turn the redacted PlayerView (all the
//  agent is allowed to know) into a *full-information* GameState that is
//  consistent with everything public. Sample many of these and you have the
//  "determinized" worlds the agent solves and averages over. This is
//  structurally the same move as a bracket Monte Carlo: sample hidden state
//  consistent with observed constraints, evaluate, aggregate.
//
//  The agent NEVER reads another seat's real hand. It only ever sees a
//  PlayerView and reconstructs plausible full deals from it. That is what
//  keeps the AI honest and what lets the exact same agent run as a remote
//  opponent later with no change.
//
//  ────────────────────────────────────────────────────────────────────────
//  ENGINE BINDING — every engine symbol this file depends on. If any of
//  these drift in GameEngine/, this is the one place to reconcile:
//
//    Card.effectiveColor(trump:) -> CardColor?      Card.isSpecial
//    Deck.full                                      CardColor.allCases
//    Seats.count / .all / .team(of:) / .next(_:)    PlayerID(_:).raw
//    Trick(leader:) / .plays / PlayedCard           Phase cases
//    PlayerView.{me,myHand,phase,toAct,trump,highBid,highBidder,
//                passed,currentTrick,completedTricks,matchScore,
//                discardAnnouncement}
//    CompletedTrickInfo.{leader,plays,winner}
//    DiscardAnnouncement.{trumpCount,moneyCards}
//    GameState memberwise init (declaration order):
//      (dealSeed,dealer,hands,widow,phase,toAct,highBid,highBidder,
//       passed,bidHistory,trump,discardAnnouncement,misdealRule,
//       endgameRule,houseRules,misdealVotes,currentTrick,completedTricks,
//       capturedByTeam,matchScore,dealtHands,dealtWidow)
//
//    PlayerView.bidHistory : [BidRecord]  (public; opener also on the view)
//
//  That initializer order is the single most fragile coupling. If a stored
//  property is added to GameState, update `rebuild(...)` below to match.
//  ────────────────────────────────────────────────────────────────────────
//

import Foundation

/// A sampled full-information world plus the seat the agent is reasoning as.
struct AIWorld {
    /// A real GameState with every hand filled in. Drive it with the engine's
    /// own `applying(_:by:)` — no rule is re-implemented anywhere in the AI.
    let state: GameState
    /// The seat we are deciding for (whose real hand is the one true fact).
    let me: PlayerID
}

/// The auction-reading model shared by BOTH the trick-play `Determinizer` and
/// the bid-time deal sampler in `MonteCarloAgent`, so the two can never drift
/// (they were duplicated copies before). A human reads exactly this: a seat
/// that bid leans strong (scaled by how far above the floor), a passer weak, an
/// un-acted seat neutral; strong cards then drift toward the strong-lean seats.
enum BidLean {
    /// Per hidden seat (everyone but `view.me`): + if they bid, − if they
    /// passed, 0 if they have not yet acted.
    static func bySeat(view: PlayerView) -> [PlayerID: Double] {
        var highestBid: [PlayerID: Int] = [:]
        for rec in view.bidHistory {
            if case .bid(let amt) = rec.action {
                highestBid[rec.player] = max(highestBid[rec.player] ?? 0, amt)
            }
        }
        var lean: [PlayerID: Double] = [:]
        for s in Seats.all where s != view.me {
            if let amt = highestBid[s] {
                // Bidding signals strength, scaled by how far above the floor.
                lean[s] = min(2.0, 0.5 + Double(amt - Bidding.openingMinimum) / 75_000.0)
            } else if view.passed.contains(s) {
                lean[s] = -1.0          // a pass signals a weaker hand
            } else {
                lean[s] = 0.0           // hasn't acted / unknown
            }
        }
        return lean
    }

    /// A rough 0…1 "how good is this card to hold" score — money and high rank
    /// are strong, the Tiger tops out, Bull/Bear are treated as neutral. A small
    /// same-color bonus applies when `trump` is known (it is nil at bid time).
    static func cardValue(_ c: Card, trump: CardColor?) -> Double {
        switch c {
        case .tiger: return 1.0
        case .bull, .bear: return 0.5
        case .colored(let col, let r):
            var s = Double(r.rawValue) / 12.0 * 0.5         // rank → up to 0.5
            s += Double(r.moneyValue) / 40_000.0 * 0.4      // money → up to 0.4
            if let trump, col == trump { s += 0.1 }         // trump bonus
            return min(1.0, s)
        }
    }

    /// exp(strength · centredCardValue · seatLean): >1 when a strong card meets
    /// a bidder (or a weak card meets a passer), <1 for the mismatches.
    static func weight(card: Card, seat: PlayerID,
                       lean: [PlayerID: Double], strength: Double,
                       trump: CardColor?) -> Double {
        let v = cardValue(card, trump: trump) - 0.5         // [-0.5, +0.5]
        let l = lean[seat] ?? 0.0                            // [-1, +2]
        return exp(strength * v * l)
    }
}

/// Builds determinized worlds from a PlayerView. Deterministic given its seed
/// so a weird AI decision is reproducible — same property the engine and the
/// RandomAgent already have.
struct Determinizer {

    let view: PlayerView
    private var rng: SeededRNG
    /// How strongly bid history biases the deal. 0 = uniform (old behaviour);
    /// higher = passers get weaker hands and bidders stronger ones. This is a
    /// soft prior — it shifts the *distribution* of sampled worlds, it never
    /// violates a hard constraint (counts, voids).
    private let bidLeanStrength: Double
    /// Per hidden seat: + if they bid (scaled by amount), − if they passed.
    /// A human reads exactly this signal: "everyone passed, so they're weak."
    private let lean: [PlayerID: Double]
    /// When true, the declarer's un-discardable widow cards are pinned into the
    /// declarer's sampled hand (a hard fact) rather than scattered. See the
    /// `Difficulty.deduceWidowHoldings` lever.
    private let deduceWidowHoldings: Bool
    /// SHAPE prior: bias trump cards toward the declarer (they named trump, so
    /// they're likely long in it). 0 = off. See `Difficulty.declarerTrumpBias`.
    private let declarerTrumpBias: Double
    /// Play-consistency rejection checks (see `isDominatedPlay`). Each is
    /// independently A/B-able. When both are false, `isConsistentWithPlay` is a
    /// no-op and `sampleConsistent` behaves exactly like `sample`.
    private let filterDominatedDonation: Bool
    private let filterBearDecline: Bool

    init(view: PlayerView, seed: UInt64,
         bidLeanStrength: Double = 0.0,
         deduceWidowHoldings: Bool = false,
         declarerTrumpBias: Double = 0.0,
         filterDominatedDonation: Bool = false,
         filterBearDecline: Bool = false) {
        self.view = view
        self.rng = SeededRNG(seed: seed)
        self.bidLeanStrength = bidLeanStrength
        self.deduceWidowHoldings = deduceWidowHoldings
        self.declarerTrumpBias = declarerTrumpBias
        self.filterDominatedDonation = filterDominatedDonation
        self.filterBearDecline = filterBearDecline
        self.lean = BidLean.bySeat(view: view)
    }

    // MARK: Public knowledge derived once

    /// Every card that has been played so far (completed tricks + the trick
    /// in progress). Public — everyone at the table watched these.
    private var playedCards: [Card] {
        var out: [Card] = []
        for t in view.completedTricks { out += t.plays.map(\.card) }
        if let cur = view.currentTrick { out += cur.plays.map(\.card) }
        return out
    }

    /// How many cards each *other* seat still holds. My own count is
    /// authoritative from the view; others are 13 minus what they've played.
    private func remainingCount(for seat: PlayerID) -> Int {
        if seat == view.me { return view.myHand.count }
        var played = 0
        for t in view.completedTricks {
            played += t.plays.filter { $0.player == seat }.count
        }
        if let cur = view.currentTrick {
            played += cur.plays.filter { $0.player == seat }.count
        }
        return 13 - played
    }

    /// Void inference — the single highest-value deduction in trick play.
    /// If a seat failed to follow the led color in any completed trick (or
    /// the trick in progress), it provably holds no card of that color.
    /// Bull/Bear have no effective color, and the engine only lets them be
    /// played when the seat *cannot* follow — so those plays imply a void
    /// too. Tiger counts as trump.
    private func inferredVoids(trump: CardColor) -> [PlayerID: Set<CardColor>] {
        var voids: [PlayerID: Set<CardColor>] = [:]

        func scan(_ trick: Trick) {
            guard let led = trick.ledColor(trump: trump) else { return }
            for pc in trick.plays where pc.player != trick.leader {
                let ec = pc.card.effectiveColor(trump: trump)
                if ec != led {
                    // Did not follow the led color ⇒ void in it.
                    voids[pc.player, default: []].insert(led)
                }
            }
        }
        for info in view.completedTricks {
            scan(Trick(leader: info.leader, plays: info.plays))
        }
        if let cur = view.currentTrick { scan(cur) }
        return voids
    }

    /// HARD widow deduction (principle 11). The engine forbids discarding the
    /// Tiger / Bull / Bear from the widow, and any money card it DOES allow
    /// out (last-resort rule) is revealed in the public announcement — so a
    /// special or money card in the publicly-revealed widow that was neither
    /// played nor revealed as discarded is GUARANTEED to be in the declarer's
    /// hand right now. Returns the declarer and the cards they must still
    /// hold. nil when there's nothing to pin (I'm the declarer,
    /// pre-trick-play, or no locked cards remain unplayed).
    private func widowLockedInDeclarer() -> (declarer: PlayerID, cards: [Card])? {
        guard let declarer = view.highBidder,
              declarer != view.me,
              let widow = view.widow else { return nil }
        let seen = Set(playedCards)
        let revealed = Set(view.discardAnnouncement?.moneyCards ?? [])
        let locked = widow.filter {
            ($0.isSpecial || $0.isMoney)
                && !seen.contains($0) && !revealed.contains($0)
        }
        return locked.isEmpty ? nil : (declarer, locked)
    }

    // MARK: Sampling

    /// Produce one determinized world consistent with the view. Returns nil
    /// only if the constraints are unsatisfiable after bounded retries
    /// (extremely rare; caller falls back to an unconstrained deal).
    mutating func sample() -> AIWorld? {
        // Cards not visible to me = full deck minus my hand minus everything
        // played. During trick play this pool also contains the 3 discarded
        // widow cards, which belong to nobody ("dead"); we deal those into a
        // throwaway pile so opponent hand sizes stay exact.
        var pool = Deck.full
        let known = Set(view.myHand) .union(playedCards)
        pool.removeAll { known.contains($0) }

        // Announced discard facts (public, hard): money discards were shown
        // face-up — they are DEAD, in nobody's hand. Remove them like played
        // cards. The face-down remainder of the discard (announced trump
        // count + plain filler) is drawn per attempt inside the retry loop
        // below, so the dead pile's composition matches what the whole table
        // heard without one unlucky identity pick wedging the void deal.
        if let ann = view.discardAnnouncement {
            let revealed = Set(ann.moneyCards)
            pool.removeAll { revealed.contains($0) }
        }

        let others = Seats.all.filter { $0 != view.me }

        // HARD widow deduction: pin the declarer's un-discardable widow cards
        // into their hand up front (Extreme tier). Removed from the pool and
        // counted against the declarer's target so the remaining deal stays
        // exact; they bypass the void deal since holding them is a fact.
        var preplaced: [PlayerID: [Card]] = [:]
        if deduceWidowHoldings, let (declarer, locked) = widowLockedInDeclarer() {
            let pinnable = locked.filter { pool.contains($0) }
            let cap = max(0, remainingCount(for: declarer))
            let take = Array(pinnable.prefix(cap))
            if !take.isEmpty {
                preplaced[declarer] = take
                let taken = Set(take)
                pool.removeAll { taken.contains($0) }
            }
        }

        let trumpForVoids = view.trump
        let voids = trumpForVoids.map(inferredVoids(trump:)) ?? [:]

        // Target hand sizes for the other seats (minus anything pre-placed).
        var need: [PlayerID: Int] = [:]
        for s in others {
            need[s] = max(0, remainingCount(for: s) - (preplaced[s]?.count ?? 0))
        }

        // Constrained deal with bounded backtracking. Cards with a concrete
        // effective color may not go to a seat void in that color. Specials
        // (nil effective color) and the dead pile are unconstrained.
        for _ in 0..<24 {
            // Per-attempt pool: bury the face-down part of the announced
            // discard (exact trump count, plain filler) with fresh random
            // identities each try — only the COMPOSITION is public.
            var attempt = pool
            if let ann = view.discardAnnouncement, let t = view.trump {
                removeRandomDead(from: &attempt, count: ann.trumpCount) {
                    !$0.isSpecial && !$0.isMoney && $0.effectiveColor(trump: t) == t
                }
                removeRandomDead(from: &attempt,
                                 count: 3 - ann.trumpCount - ann.moneyCards.count) {
                    !$0.isSpecial && !$0.isMoney && $0.effectiveColor(trump: t) != t
                }
            }
            let deadCount = attempt.count - need.values.reduce(0, +)   // discarded widow etc.
            guard deadCount >= 0 else {
                // Bookkeeping mismatch — should never happen; bail to fallback.
                return nil
            }
            shuffle(&attempt)
            if let hands = tryDeal(pool: attempt,
                                   to: others,
                                   sizes: need,
                                   dead: deadCount,
                                   voids: voids,
                                   trump: trumpForVoids) {
                var full = hands
                for (seat, cards) in preplaced {
                    full[seat, default: []].append(contentsOf: cards)
                }
                full[view.me] = view.myHand
                if let st = rebuild(hands: full) {
                    return AIWorld(state: st, me: view.me)
                }
                return nil
            }
        }
        return nil
    }

    /// Remove up to `count` randomly-chosen cards matching `match` from the
    /// pool — dead cards that belong to no seat (the face-down part of the
    /// announced discard). A shortfall is tolerated: an inconsistent
    /// announcement (impossible in engine-produced views) degrades to the
    /// count-only dead handling in `tryDeal` rather than failing the sample.
    private mutating func removeRandomDead(from pool: inout [Card],
                                           count: Int,
                                           where match: (Card) -> Bool) {
        var remaining = count
        while remaining > 0 {
            let candidates = pool.indices.filter { match(pool[$0]) }
            guard !candidates.isEmpty else { return }
            pool.remove(at: candidates[Int(rng.next() % UInt64(candidates.count))])
            remaining -= 1
        }
    }

    /// Best-effort fallback: ignore void constraints, just respect counts.
    /// Used only if `sample()` fails repeatedly, so rare it barely affects
    /// the average — but it guarantees the agent always has worlds to reason
    /// over rather than stalling. Revealed money discards are still excluded
    /// — that is a hard public fact, not a void inference.
    mutating func sampleUnconstrained() -> AIWorld? {
        var pool = Deck.full
        var known = Set(view.myHand).union(playedCards)
        known.formUnion(view.discardAnnouncement?.moneyCards ?? [])
        pool.removeAll { known.contains($0) }
        shuffle(&pool)

        let others = Seats.all.filter { $0 != view.me }
        var hands: [PlayerID: [Card]] = [:]
        var cursor = 0
        for s in others {
            let n = max(0, remainingCount(for: s))
            hands[s] = Array(pool[cursor..<min(cursor + n, pool.count)])
            cursor += n
        }
        hands[view.me] = view.myHand
        guard let st = rebuild(hands: hands) else { return nil }
        return AIWorld(state: st, me: view.me)
    }

    // MARK: Play-consistency filtering

    /// Floor (dollars already on the table) above which DECLINING a legal Bear
    /// on a certainly-lost trick counts as dominated. High enough that "saving
    /// the Bear for a bigger pot" is not a credible alternative line.
    private static let bearDeclineFloor = 30_000
    /// Keep the soft play-history importance sampler bounded. The newest
    /// tricks are the strongest evidence about the cards still in hand, while
    /// replaying the whole hand for every sampled world is too expensive for
    /// an opt-in search prior.
    private static let playHistoryWeightTrickWindow = 4

    /// Like `sample()` but rejects worlds that flunk `isConsistentWithPlay`.
    /// Tries a bounded number of fresh samples, then falls back to the last
    /// constrained world (or the unconstrained deal) so the search never
    /// stalls for want of a "perfect" world.
    mutating func sampleConsistent(maxAttempts: Int = 6) -> AIWorld? {
        var last: AIWorld? = nil
        for _ in 0..<maxAttempts {
            guard let w = sample() else { break }
            last = w
            if isConsistentWithPlay(w) { return w }
        }
        return last ?? sampleUnconstrained()
    }

    /// Replay the public trick history through the ENGINE in this sampled
    /// world and return false if any HIDDEN seat is forced to have made a
    /// provably-dominated past play (see `isDominatedPlay`). No rule is
    /// re-implemented — the engine generates the legal moves and resolves each
    /// trick. Fail-OPEN: any reconstruction/replay mismatch returns true
    /// (accept), so the filter only ever REMOVES clearly-impossible worlds and
    /// never invents a constraint the sampler didn't already honour.
    func isConsistentWithPlay(_ world: AIWorld) -> Bool {
        guard let trump = view.trump else { return true }     // trick play only

        // Ordered public record of every card played so far.
        var history: [PlayedCard] = []
        for t in view.completedTricks { history += t.plays }
        if let cur = view.currentTrick { history += cur.plays }
        guard !history.isEmpty else { return true }

        // Each seat's hand at the START of trick play = its current sampled
        // remainder plus everything it has since played (all public).
        var initial: [PlayerID: [Card]] = world.state.hands
        for pc in history { initial[pc.player, default: []].append(pc.card) }

        guard let leader = view.completedTricks.first?.leader
                ?? view.currentTrick?.leader else { return true }
        var state = rebuildInitial(hands: initial, leader: leader)

        for pc in history {
            if pc.player != view.me {
                let legal = state.legalMoves(for: pc.player).compactMap {
                    move -> Card? in
                    if case .play(let c) = move { return c }
                    return nil
                }
                if isDominatedPlay(actual: pc.card, legal: legal,
                                   trick: state.currentTrick,
                                   seat: pc.player, trump: trump) {
                    return false
                }
            }
            guard let next = try? state.applying(.play(pc.card), by: pc.player)
            else { return true }      // replay desync (rare) → accept the world
            state = next
        }
        return true
    }

    /// Soft counterpart to `isConsistentWithPlay`: return an importance weight
    /// for a sampled world based on how plausible the already-public hidden-seat
    /// plays look in that world. This avoids the hard-filter trap: odd plays
    /// nudge the world down, high-signal plays nudge it up, but no otherwise
    /// legal world is deleted outright.
    func playHistoryWeight(_ world: AIWorld,
                           strength: Double) -> Double {
        guard strength > 0, let trump = view.trump else { return 1.0 }

        guard let replay = recentHistoryForWeighting() else { return 1.0 }
        let history = replay.plays

        var initial: [PlayerID: [Card]] = world.state.hands
        for pc in history { initial[pc.player, default: []].append(pc.card) }

        var state = rebuildInitial(hands: initial, leader: replay.leader)
        var logWeight = 0.0

        for pc in history {
            if pc.player != view.me {
                let legalMoves = state.legalMoves(for: pc.player)
                let legalCards = legalMoves.compactMap { $0.playedCard }
                guard legalCards.contains(pc.card) else { return 1.0 } // replay mismatch -> fail open
                let likelihood = highConfidencePlayLikelihood(
                    actual: pc.card,
                    legal: legalCards,
                    trick: state.currentTrick,
                    seat: pc.player,
                    trump: trump)
                logWeight += log(likelihood)
            }
            guard let next = try? state.applying(.play(pc.card), by: pc.player)
            else { return 1.0 }
            state = next
        }

        // Bounded importance sampling: enough to prefer human-plausible worlds,
        // not enough for one fragile rationality assumption to dominate.
        let scaled = logWeight * strength
        let lo = log(0.45)
        let hi = log(2.25)
        return exp(min(hi, max(lo, scaled)))
    }

    private func recentHistoryForWeighting() -> (leader: PlayerID, plays: [PlayedCard])? {
        var tricks: [(leader: PlayerID, plays: [PlayedCard])] =
            view.completedTricks.map { ($0.leader, $0.plays) }
        if let cur = view.currentTrick, !cur.plays.isEmpty {
            tricks.append((cur.leader, cur.plays))
        }
        let recent = tricks.suffix(Self.playHistoryWeightTrickWindow)
        guard let leader = recent.first?.leader else { return nil }
        let plays = recent.flatMap { $0.plays }
        return plays.isEmpty ? nil : (leader, plays)
    }

    private func highConfidencePlayLikelihood(actual: Card,
                                              legal: [Card],
                                              trick: Trick?,
                                              seat: PlayerID,
                                              trump: CardColor) -> Double {
        guard legal.count > 1, let trick else { return 1.0 }
        let led = trick.ledColor(trump: trump)
        let myTeam = Seats.team(of: seat)
        let moneyOnTable = trick.plays.reduce(0) { $0 + $1.card.moneyValue }
        let currentValue = PlayoutPolicy.tableValue(trick.plays)
        let beared = PlayoutPolicy.tableIsBeared(trick.plays)
        let amLastToPlay = trick.plays.count == Seats.count - 1

        func wouldWin(_ card: Card) -> Bool {
            var t = trick
            t.plays.append(PlayedCard(player: seat, card: card))
            return GameState.trickWinner(t, trump: trump) == seat
        }
        func winnerTeam(after card: Card) -> Int {
            var t = trick
            t.plays.append(PlayedCard(player: seat, card: card))
            return Seats.team(of: GameState.trickWinner(t, trump: trump))
        }

        let actualWins = wouldWin(actual)
        let anyTeamWin = legal.contains { winnerTeam(after: $0) == myTeam }
        let partnerWinningBeforePlay: Bool = {
            guard !trick.plays.isEmpty else { return false }
            let winner = GameState.trickWinner(trick, trump: trump)
            return Seats.team(of: winner) == myTeam && winner != seat
        }()
        let opponentWinningBeforePlay: Bool = {
            guard !trick.plays.isEmpty else { return false }
            let winner = GameState.trickWinner(trick, trump: trump)
            return Seats.team(of: winner) != myTeam
        }()

        // Bear timing is high-signal because it is legal only when void. A Bear
        // on an enemy money trick is usually meaningful; declining it when last
        // to play and unable to win is suspicious but not impossible.
        if actual.isBear {
            if opponentWinningBeforePlay && currentValue >= 10_000 { return 1.22 }
            if partnerWinningBeforePlay && moneyOnTable > 0 { return 0.70 }
            return 0.96
        }
        if legal.contains(where: { $0.isBear }),
           !actualWins, amLastToPlay, !anyTeamWin, currentValue >= 30_000 {
            return 0.82
        }

        // Bull timing is also high-signal. It is excellent on partner money,
        // bad when it doubles an enemy pot, and mostly neutral on empty pots.
        if actual.isBull {
            if partnerWinningBeforePlay && moneyOnTable > 0 && !beared { return 1.20 }
            if opponentWinningBeforePlay && moneyOnTable > 0 { return 0.70 }
            return 0.96
        }

        // The old hard donation filter failed because small money often *is*
        // the lowest capture-rank legal card. Only treat larger money donated
        // to a certain loss as evidence, and even then only softly.
        if actual.moneyValue >= 15_000,
           !actualWins, !anyTeamWin,
           hasCheaperNonMoneyAlternative(than: actual, legal: legal,
                                         led: led, trump: trump) {
            return 0.86
        }

        // Money fed to a partner-controlled live trick is a good clue that the
        // seat lacked a better future for it. Avoid broad policy-agreement
        // scoring; this boost is intentionally narrow.
        if actual.isMoney, partnerWinningBeforePlay, !beared {
            return 1.10
        }
        if actual.isMoney, beared {
            return 0.88
        }

        return 1.0
    }

    private func hasCheaperNonMoneyAlternative(than card: Card,
                                               legal: [Card],
                                               led: CardColor?,
                                               trump: CardColor) -> Bool {
        let cardStrength = PlayoutPolicy.strength(card, led: led, trump: trump)
        return legal.contains {
            !$0.isMoney && !$0.isSpecial
                && PlayoutPolicy.strength($0, led: led, trump: trump) <= cardStrength
        }
    }

    /// True iff `actual` is a provably-dominated play here: the seat is LAST to
    /// play (so the winner is fully determined), the trick goes to the
    /// OPPONENTS no matter what the seat plays, and the seat either
    ///   (A) spent money or the Bull (which DOUBLES the enemy's take) when a
    ///       worthless throwaway was legal, or
    ///   (B) declined the legal Bear that would have zeroed a fat enemy pot.
    /// Both are blunders no rational line makes, so a world that requires one
    /// is near-impossible. Conservative everywhere else (returns false), to
    /// keep false rejections near zero.
    private func isDominatedPlay(actual: Card, legal: [Card], trick: Trick?,
                                 seat: PlayerID, trump: CardColor) -> Bool {
        guard let trick = trick,
              trick.plays.count == Seats.count - 1 else { return false }
        let myTeam = Seats.team(of: seat)
        func winnerTeam(after card: Card) -> Int {
            var t = trick
            t.plays.append(PlayedCard(player: seat, card: card))
            return Seats.team(of: GameState.trickWinner(t, trump: trump))
        }
        // If the seat can secure the trick for its team (overtake, or it is
        // already going to its partner), this is a live contest, not a certain
        // loss — don't judge it.
        guard !legal.contains(where: { winnerTeam(after: $0) == myTeam }) else {
            return false
        }
        // (A) Money / Bull donated into a certain loss when a worthless card
        //     (non-money, non-special) was a legal alternative.
        if filterDominatedDonation,
           actual.isMoney || actual.isBull,
           legal.contains(where: { !$0.isMoney && !$0.isSpecial }) {
            return true
        }
        // (B) Legal Bear declined on a fat certain loss.
        if filterBearDecline,
           !actual.isBear, legal.contains(where: { $0.isBear }) {
            let pot = trick.plays.reduce(0) { $0 + $1.card.moneyValue }
            if pot >= Self.bearDeclineFloor { return true }
        }
        return false
    }

    /// A start-of-trick-play `GameState` for this world: the reconstructed
    /// 13-card hands, the known trump, `leader` on lead, no tricks yet. Mirrors
    /// `rebuild` but at trick 1; used only to replay the public history for the
    /// play-consistency filter. `misdealRule: .disabled` (no redeals in replay).
    private func rebuildInitial(hands: [PlayerID: [Card]],
                                leader: PlayerID) -> GameState {
        GameState(
            dealSeed: 0,
            dealer: PlayerID(0),
            hands: hands,
            widow: [],
            phase: .trickPlay,
            toAct: leader,
            highBid: view.highBid,
            highBidder: view.highBidder,
            passed: Set(view.passed),
            bidHistory: view.bidHistory,
            trump: view.trump,
            discardAnnouncement: view.discardAnnouncement,
            misdealRule: .disabled,
            endgameRule: .standard,
            houseRules: view.houseRules,
            currentTrick: nil,
            completedTricks: [],
            capturedByTeam: [0: [], 1: []],
            matchScore: view.matchScore,
            dealtHands: [:],
            dealtWidow: []
        )
    }

    // MARK: Deal mechanics

    private mutating func tryDeal(pool: [Card],
                                  to seats: [PlayerID],
                                  sizes: [PlayerID: Int],
                                  dead: Int,
                                  voids: [PlayerID: Set<CardColor>],
                                  trump: CardColor?) -> [PlayerID: [Card]]? {
        var hands: [PlayerID: [Card]] = [:]
        for s in seats { hands[s] = [] }
        var deadLeft = dead

        // Hardest-constrained cards first: a card whose color is void-banned
        // for the most seats has the fewest homes, so place it early.
        func banned(_ card: Card, _ seat: PlayerID) -> Bool {
            guard let t = trump,
                  let ec = card.effectiveColor(trump: t),
                  let v = voids[seat] else { return false }
            return v.contains(ec)
        }
        // A card's ban-count (how many seats its color is void-blocked for)
        // depends only on the card and the voids, not on the pool, so compute
        // it ONCE per card instead of re-filtering all seats on every one of
        // the sort's O(n log n) comparisons.
        var banCount: [Card: Int] = [:]
        banCount.reserveCapacity(pool.count)
        for c in pool where banCount[c] == nil {
            banCount[c] = seats.reduce(0) { $0 + (banned(c, $1) ? 1 : 0) }
        }
        let ordered = pool.sorted { (banCount[$0] ?? 0) > (banCount[$1] ?? 0) }

        for card in ordered {
            // Eligible seats that still need cards and aren't void-blocked.
            let candidates = seats.filter {
                hands[$0]!.count < (sizes[$0] ?? 0) && !banned(card, $0)
            }
            if !candidates.isEmpty {
                // Bias the choice by bid-lean: strong cards drift toward seats
                // that bid, weak cards toward seats that passed. Still random
                // (so samples stay diverse) and still only among eligible
                // seats (so no hard constraint is broken).
                let pick = weightedPick(candidates, card: card)
                hands[pick]!.append(card)
            } else if deadLeft > 0 {
                deadLeft -= 1                      // goes to the discarded pile
            } else {
                return nil                          // dead end → caller retries
            }
        }
        // Every seat must be exactly filled.
        for s in seats where hands[s]!.count != (sizes[s] ?? 0) { return nil }
        return hands
    }

    /// Pick one seat from `candidates`, weighted by bid-lean × card strength.
    /// With `bidLeanStrength == 0` this is just `candidates[0]`, preserving the
    /// previous (uniform-after-shuffle) behaviour exactly.
    private mutating func weightedPick(_ candidates: [PlayerID], card: Card) -> PlayerID {
        if candidates.count == 1 { return candidates[0] }
        if bidLeanStrength <= 0 && declarerTrumpBias <= 0 { return candidates[0] }
        let weights = candidates.map { seat -> Double in
            var w = BidLean.weight(card: card, seat: seat, lean: lean,
                                   strength: bidLeanStrength, trump: view.trump)
            // Shape prior: the declarer named trump → likely long in it. Pull
            // trump cards (any rank) toward the declarer; the lean weight only
            // captures strength, so it misses low-trump length.
            if declarerTrumpBias > 0,
               let t = view.trump, let d = view.highBidder, d != view.me,
               seat == d, card.effectiveColor(trump: t) == t {
                w *= exp(declarerTrumpBias)
            }
            return w
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return candidates[0] }
        let r = Double(rng.next() % 1_000_000) / 1_000_000.0 * total
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if r <= acc { return candidates[i] }
        }
        return candidates[candidates.count - 1]
    }

    private mutating func shuffle(_ a: inout [Card]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
    }

    // MARK: Rebuild a real GameState from public view + sampled hands

    /// Reassemble a full GameState consistent with the view. `dealSeed` and
    /// `dealer` are not public; we use placeholders because no reachable
    /// transition from bidding-onward consults them (misdeal redeal and the
    /// degenerate all-pass branch are the only readers, and rollouts never
    /// enter them). `misdealRule: .disabled` makes redeals impossible in
    /// the rollout, which is the correct rollout semantics.
    private func rebuild(hands: [PlayerID: [Card]]) -> GameState? {
        // Public completed tricks → engine Tricks + capturedByTeam grouping.
        var completed: [Trick] = []
        var captured: [Int: [Trick]] = [0: [], 1: []]
        for info in view.completedTricks {
            let t = Trick(leader: info.leader, plays: info.plays)
            completed.append(t)
            captured[Seats.team(of: info.winner), default: []].append(t)
        }

        return GameState(
            dealSeed: 0,
            dealer: PlayerID(0),
            hands: hands,
            widow: [],                       // taken before trick play
            phase: view.phase,
            toAct: view.toAct,
            highBid: view.highBid,
            highBidder: view.highBidder,
            passed: Set(view.passed),
            // bidHistory is declared right after `passed` in GameState, so
            // the memberwise initializer requires it here. Public record,
            // carried faithfully from the view.
            bidHistory: view.bidHistory,
            trump: view.trump,
            discardAnnouncement: view.discardAnnouncement,
            misdealRule: .disabled,
            // Rollouts never reach a match-deciding settle, so the endgame
            // tiebreak is irrelevant here; the standard rule is a safe default.
            endgameRule: .standard,
            // House rules change move LEGALITY (e.g. trump may not be led
            // until broken), so rollouts must play under the table's rules —
            // otherwise the search would credit lines the engine forbids.
            houseRules: view.houseRules,
            currentTrick: view.currentTrick,
            completedTricks: completed,
            capturedByTeam: captured,
            matchScore: view.matchScore,
            // Dealt-hand snapshots are a debug-reveal concern only — no rule
            // or rollout reads them, so empty placeholders are correct here.
            dealtHands: [:],
            dealtWidow: []
        )
    }
}
