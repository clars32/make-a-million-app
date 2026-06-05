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
//                passed,currentTrick,completedTricks,matchScore}
//    CompletedTrickInfo.{leader,plays,winner}
//    GameState memberwise init (declaration order):
//      (dealSeed,dealer,hands,widow,phase,toAct,highBid,highBidder,
//       passed,bidHistory,trump,misdealRule,currentTrick,
//       completedTricks,capturedByTeam,matchScore,dealtHands,dealtWidow)
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

    init(view: PlayerView, seed: UInt64,
         bidLeanStrength: Double = 0.0,
         deduceWidowHoldings: Bool = false) {
        self.view = view
        self.rng = SeededRNG(seed: seed)
        self.bidLeanStrength = bidLeanStrength
        self.deduceWidowHoldings = deduceWidowHoldings
        self.lean = Determinizer.computeLean(view: view)
    }

    /// Read the public bid record into a per-seat strength lean.
    private static func computeLean(view: PlayerView) -> [PlayerID: Double] {
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
        for t in view.completedTricks where true {
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
    /// Tiger / Bull / Bear / any money card from the widow, so any such card in
    /// the publicly-revealed widow is GUARANTEED to be in the declarer's hand
    /// right now — unless we've since seen it played. Returns the declarer and
    /// the cards they must still hold. nil when there's nothing to pin (I'm the
    /// declarer, pre-trick-play, or no locked cards remain unplayed).
    private func widowLockedInDeclarer() -> (declarer: PlayerID, cards: [Card])? {
        guard let declarer = view.highBidder,
              declarer != view.me,
              let widow = view.widow else { return nil }
        let seen = Set(playedCards)
        let locked = widow.filter {
            ($0.isSpecial || $0.isMoney) && !seen.contains($0)
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

        shuffle(&pool)

        let trumpForVoids = view.trump
        let voids = trumpForVoids.map(inferredVoids(trump:)) ?? [:]

        // Target hand sizes for the other seats (minus anything pre-placed).
        var need: [PlayerID: Int] = [:]
        for s in others {
            need[s] = max(0, remainingCount(for: s) - (preplaced[s]?.count ?? 0))
        }
        let deadCount = pool.count - need.values.reduce(0, +)   // discarded widow etc.

        guard deadCount >= 0 else {
            // Bookkeeping mismatch — should never happen; bail to fallback.
            return nil
        }

        // Constrained deal with bounded backtracking. Cards with a concrete
        // effective color may not go to a seat void in that color. Specials
        // (nil effective color) and the dead pile are unconstrained.
        for _ in 0..<24 {
            if let hands = tryDeal(pool: pool,
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
            shuffle(&pool)
        }
        return nil
    }

    /// Best-effort fallback: ignore void constraints, just respect counts.
    /// Used only if `sample()` fails repeatedly, so rare it barely affects
    /// the average — but it guarantees the agent always has worlds to reason
    /// over rather than stalling.
    mutating func sampleUnconstrained() -> AIWorld? {
        var pool = Deck.full
        let known = Set(view.myHand).union(playedCards)
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
        let ordered = pool.sorted { a, b in
            let na = seats.filter { banned(a, $0) }.count
            let nb = seats.filter { banned(b, $0) }.count
            return na > nb
        }

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
        if candidates.count == 1 || bidLeanStrength <= 0 { return candidates[0] }
        let weights = candidates.map { leanWeight(card: card, seat: $0) }
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

    /// exp(strength × centredCardValue × seatLean): >1 when a strong card meets
    /// a bidder (or a weak card meets a passer), <1 for the mismatches.
    private func leanWeight(card: Card, seat: PlayerID) -> Double {
        let v = cardValueScore(card) - 0.5         // [-0.5, +0.5]
        let l = lean[seat] ?? 0.0                   // [-1, +2]
        return exp(bidLeanStrength * v * l)
    }

    /// A rough 0…1 "how good is this card to hold" score, for bid-lean only —
    /// money and high rank are strong, low pips are weak, Tiger is the top.
    private func cardValueScore(_ c: Card) -> Double {
        switch c {
        case .tiger: return 1.0
        case .bull, .bear: return 0.5               // situational, treat as neutral
        case .colored(let col, let r):
            var s = Double(r.rawValue) / 12.0 * 0.5         // rank → up to 0.5
            s += Double(r.moneyValue) / 40_000.0 * 0.4      // money → up to 0.4
            if let t = view.trump, col == t { s += 0.1 }    // trump bonus
            return min(1.0, s)
        }
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
            misdealRule: .disabled,
            // Rollouts never reach a match-deciding settle, so the endgame
            // tiebreak is irrelevant here; the standard rule is a safe default.
            endgameRule: .standard,
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
