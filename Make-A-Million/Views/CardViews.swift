//
//  CardViews.swift
//  Make-a-Million
//
//  Shared card-rendering primitives used by every surface that draws cards:
//  the solo/host GameBody, the hand-only client phone, and the tabletop board.
//  Keeping the card face and the fanned-hand geometry in one place means the
//  three surfaces never drift apart visually.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Stable identity for animation / ForEach

/// A deal-order-independent key so a given card keeps the same SwiftUI
/// identity (for matchedGeometry and ForEach) no matter how the hand sorts.
struct CardKey: Hashable {
    let g: Int
    let c: Int
    let r: Int
}

private func cardSortKey(_ card: Card) -> (group: Int, color: Int, rank: Int) {
    switch card {
    case .colored(let color, let rank): return (0, color.rawValue, rank.rawValue)
    case .tiger: return (1, 0, 0)
    case .bull:  return (1, 0, 1)
    case .bear:  return (1, 0, 2)
    }
}

func cardKey(_ card: Card) -> CardKey {
    let k = cardSortKey(card)
    return CardKey(g: k.group, c: k.color, r: k.rank)
}

/// Hand display order: colored cards first (by color then rank), specials last.
func sortedHand(_ hand: [Card]) -> [Card] {
    hand.sorted { lhs, rhs in
        let l = cardSortKey(lhs)
        let r = cardSortKey(rhs)
        if l.group != r.group { return l.group > r.group }
        if l.color != r.color { return l.color > r.color }
        return l.rank > r.rank
    }
}

func keyedHand(_ hand: [Card]) -> [(key: CardKey, card: Card)] {
    sortedHand(hand).map { (cardKey($0), $0) }
}

func keyedPlays(_ plays: [PlayedCard]) -> [(key: CardKey, play: PlayedCard)] {
    plays.map { (cardKey($0.card), $0) }
}

// MARK: - Card face

/// A single playing card. Sizes (font, dot, padding, corner) scale off the
/// card height so the same view renders cleanly from a 26pt mini chip to a
/// full-size hand card.
struct CardFace: View {
    let card: Card
    var faded: Bool = false
    var selected: Bool = false
    var highlighted: Bool = false
    var width: CGFloat = 60
    var height: CGFloat = 85
    /// Crowded hands (16 cards during trump-naming/discard) shrink the label.
    var dense: Bool = false

    private var tint: Color { card.tint == .primary ? .black : card.tint }
    private var corner: CGFloat { height * 0.14 }
    private var labelSize: CGFloat { height * (dense ? 0.12 : 0.16) }
    private var dot: CGFloat { height * 0.075 }
    private var pad: CGFloat { height * 0.075 }

    var body: some View {
        cardBody
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor
                            : (highlighted ? Color.green : Color.gray.opacity(0.3)),
                        lineWidth: (selected || highlighted) ? 2.5 : 0.5))
            .shadow(
                color: .black.opacity(selected ? 0.3 : 0.15),
                radius: selected ? 8 : 2,
                y: selected ? 4 : 1)
            .frame(width: width, height: height)
            .opacity(faded ? 0.5 : 1.0)
            .scaleEffect(selected ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
    }

    @ViewBuilder
    private var cardBody: some View {
        if let image = cardAssetImage {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white)
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            drawnCardBody
        }
    }

    private var drawnCardBody: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white)
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.shortLabel)
                        .font(.system(size: labelSize, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Circle().fill(tint).frame(width: dot, height: dot)
                }
                .padding(.top, pad)
                .padding(.leading, pad)
                .foregroundStyle(tint),
                alignment: .topLeading)
    }

    #if canImport(UIKit)
    private var cardAssetImage: UIImage? {
        UIImage(named: card.assetImageName)
    }
    #else
    private var cardAssetImage: Never? { nil }
    #endif
}

private extension Card {
    var assetImageName: String {
        switch self {
        case .colored(let color, let rank):
            return "card_\(color.assetCode)\(rank.assetCode)"
        case .tiger:
            return "card_tiger"
        case .bull:
            return "card_bull"
        case .bear:
            return "card_bear"
        }
    }
}

private extension CardColor {
    var assetCode: String {
        switch self {
        case .red: return "r"
        case .yellow: return "y"
        case .black: return "b"
        case .green: return "g"
        }
    }
}

private extension Card.Rank {
    var assetCode: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .money5k: return "5"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .money10k: return "10"
        case .eleven: return "11"
        case .money15k: return "15"
        case .money30k: return "30"
        case .money40k: return "40"
        }
    }
}

/// A compact card chip for dense summaries (widow, last trick).
struct MiniCardFace: View {
    let card: Card
    var faded: Bool = false

    private var tint: Color { card.tint == .primary ? .black : card.tint }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            .overlay(
                HStack(spacing: 2) {
                    Text(card.shortLabel)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Circle().fill(tint).frame(width: 4, height: 4)
                }
                .padding(.horizontal, 4)
                .foregroundStyle(tint))
            .frame(width: 38, height: 26)
            .opacity(faded ? 0.5 : 1.0)
    }
}

// MARK: - Fanned hand

/// The arced, overlapping hand of cards. Owns only the layout geometry
/// (spacing, rotation, dip, z-order, selection lift); the caller supplies the
/// per-card view (so it can attach taps, matchedGeometry, highlight, etc.).
struct FannedHand<Content: View>: View {
    let cards: [Card]
    var cardWidth: CGFloat = 60
    /// Horizontal margin reserved for the rotated outer corners.
    var rotationPad: CGFloat = 80
    var preferredOverlap: CGFloat = 30
    var anglePerCard: Double = 3.5
    var outerDip: CGFloat = 12
    /// Cards drawn lifted (e.g. selected for discard).
    var liftedCards: Set<Card> = []
    @ViewBuilder var content: (_ card: Card, _ totalCards: Int) -> Content

    var body: some View {
        let hand = keyedHand(cards)
        let n = hand.count

        GeometryReader { proxy in
            let usable = max(cardWidth, proxy.size.width - rotationPad)
            let naturalWidth = CGFloat(n) * cardWidth - CGFloat(max(0, n - 1)) * preferredOverlap
            let spacing: CGFloat = (n <= 1 || naturalWidth <= usable)
                ? -preferredOverlap
                : (usable - CGFloat(n) * cardWidth) / CGFloat(max(1, n - 1))
            let centerIndex = Double(n - 1) / 2.0
            let maxAngle = anglePerCard * centerIndex
            let radius: CGFloat = maxAngle > 0
                ? outerDip / CGFloat(1 - cos(maxAngle * .pi / 180))
                : 1

            HStack(spacing: spacing) {
                ForEach(Array(hand.enumerated()), id: \.element.key) { index, entry in
                    let offset = Double(index) - centerIndex
                    let angleDeg = offset * anglePerCard
                    let angleRad = angleDeg * .pi / 180
                    let dip = radius * CGFloat(1 - cos(angleRad))

                    content(entry.card, n)
                        .rotationEffect(.degrees(angleDeg), anchor: .bottom)
                        .offset(y: dip)
                        .offset(y: liftedCards.contains(entry.card) ? -8 : 0)
                        .zIndex(Double(index))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
