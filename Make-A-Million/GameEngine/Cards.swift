//
//  Cards.swift
//  Make-a-Million — base 4-player partnership game.
//
//  This file is deliberately concrete. There is exactly one game. The deck,
//  the ranking, and the Money values are hardcoded facts about Make-a-Million,
//  not configuration. The only thing the wider architecture keeps swappable
//  is *where moves come from* (solo / local / remote) — never the rules.
//

import Foundation

// MARK: - Color (the four suits)

enum CardColor: Int, Codable, CaseIterable, Hashable {
    case red, yellow, black, green
}

// MARK: - Card

/// A single card. Either a colored rank card or one of the three specials.
///
/// Ranking within a color, high → low:
///   $40k, $30k, $15k, 11, $10k, 9, 8, 7, $5k, 4, 3, 2, 1   (there is no 6)
///
/// We store an explicit `captureRank` so trick resolution never has to
/// reason about the gap at 6 or the interleaving of Money cards. Higher
/// `captureRank` beats lower within the same color.
enum Card: Hashable, Codable {

    case colored(CardColor, Rank)
    case tiger      // always the highest trump
    case bull       // doubles the Money value of the trick it is captured in
    case bear       // cancels the Money value of the trick it is captured in

    /// The 13 ranks present in every color. `rawValue` is the capture rank:
    /// strictly increasing with capturing power, so comparison is just `<`.
    /// Note the deliberate absence of a `six` — Make-a-Million has no 6.
    enum Rank: Int, Codable, CaseIterable, Hashable {
        case one      = 0
        case two      = 1
        case three    = 2
        case four     = 3
        case money5k  = 4    // $5,000
        case seven    = 5
        case eight    = 6
        case nine     = 7
        case money10k = 8    // $10,000
        case eleven   = 9
        case money15k = 10   // $15,000
        case money30k = 11   // $30,000
        case money40k = 12   // $40,000

        /// Money value in dollars. Non-Money ranks are worth 0.
        var moneyValue: Int {
            switch self {
            case .money5k:  return 5_000
            case .money10k: return 10_000
            case .money15k: return 15_000
            case .money30k: return 30_000
            case .money40k: return 40_000
            default:        return 0
            }
        }

        var isMoney: Bool { moneyValue > 0 }
    }

    // MARK: Derived properties

    /// Dollar value this card contributes to a trick's count. Specials are 0;
    /// the Bull/Bear modify the *trick's* total elsewhere, not via their own value.
    var moneyValue: Int {
        switch self {
        case .colored(_, let r): return r.moneyValue
        case .tiger, .bull, .bear: return 0
        }
    }

    var isMoney: Bool { moneyValue > 0 }

    /// True for the three cards with special handling in legal-move generation
    /// (Bull/Bear may only be played when you can't follow or it's your last
    /// card; none of the three may be *led* unless it's the only card left).
    var isSpecial: Bool {
        switch self {
        case .tiger, .bull, .bear: return true
        case .colored:             return false
        }
    }

    /// The color this card behaves as for following/winning, given the trump
    /// color for the hand. The Tiger behaves as trump. Bull/Bear have no
    /// color — they can never win a trick (confirmed rule) so they never need
    /// one for resolution.
    func effectiveColor(trump: CardColor) -> CardColor? {
        switch self {
        case .colored(let c, _): return c
        case .tiger:             return trump
        case .bull, .bear:       return nil
        }
    }
}

// MARK: - The 55-card deck

enum Deck {
    /// The full, ordered 55-card deck before shuffling.
    /// 4 colors × 13 ranks = 52, plus Tiger, Bull, Bear.
    static let full: [Card] = {
        var cards: [Card] = []
        for color in CardColor.allCases {
            for rank in Card.Rank.allCases {
                cards.append(.colored(color, rank))
            }
        }
        cards.append(.tiger)
        cards.append(.bull)
        cards.append(.bear)
        return cards
    }()

    /// Total Money in the deck. Consistency anchor: must equal $400,000,
    /// matching the rules' stated max hand score of "$400,000 plus what the
    /// Bull may double". The test suite asserts this.
    static let totalMoneyInDeck = 400_000
}
