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

func dealAnimationToken(for view: PlayerView?) -> Int {
    guard let view,
          view.phase != .handComplete,
          view.completedTricks.isEmpty else {
        return -1
    }

    let team0 = view.matchScore[0, default: 0] / 1000
    let team1 = view.matchScore[1, default: 0] / 1000
    return 10_000 &+ view.opener.raw &* 1_000_000 &+ team0 &* 1_000 &+ team1
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
                        selected ? TableStyle.cardSelected
                            : (highlighted ? TableStyle.cardPlayable : Color.black.opacity(0.18)),
                        lineWidth: (selected || highlighted) ? 2.5 : 0.5))
            .shadow(
                color: .black.opacity(selected ? 0.34 : 0.22),
                radius: selected ? 10 : 4,
                y: selected ? 5 : 2)
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
                        .font(TableTypography.display(size: labelSize, weight: .heavy))
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
        "card_\(assetCode)"
    }

    var miniAssetImageName: String {
        "mini_card_\(assetCode)"
    }

    private var assetCode: String {
        switch self {
        case .colored(let color, let rank):
            return "\(color.assetCode)\(rank.assetCode)"
        case .tiger:
            return "tiger"
        case .bull:
            return "bull"
        case .bear:
            return "bear"
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
    var width: CGFloat = 38
    var height: CGFloat = 26

    private var tint: Color { card.tint == .primary ? .black : card.tint }
    private var isLongPrimaryLabel: Bool { primaryMiniLabel.count >= 3 }
    private var rankSize: CGFloat { height * (isLongPrimaryLabel ? 0.48 : 0.64) }
    private var detailSize: CGFloat { height * (isLongPrimaryLabel ? 0.18 : 0.22) }
    private var horizontalPadding: CGFloat { height * (isLongPrimaryLabel ? 0.10 : 0.15) }

    var body: some View {
        indexChipBody
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: width, height: height)
            .opacity(faded ? 0.5 : 1.0)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private var indexChipBody: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white)
            .overlay(
                miniLabel
                    .lineLimit(1)
                    .minimumScaleFactor(0.42)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, horizontalPadding)
                    .foregroundStyle(tint))
    }

    private var miniLabel: Text {
        Text(primaryMiniLabel)
            .font(TableTypography.display(size: rankSize, weight: .heavy))
        + Text(" ")
        + Text(secondaryMiniLabel)
            .font(TableTypography.display(size: detailSize, weight: .heavy))
    }

    private var primaryMiniLabel: String {
        switch card {
        case .colored(_, let rank):
            return rank.label.hasPrefix("$")
                ? String(rank.label.dropFirst()) + "K"
                : rank.label
        case .tiger:
            return "T"
        case .bull:
            return "B"
        case .bear:
            return "B"
        }
    }

    private var secondaryMiniLabel: String {
        switch card {
        case .colored(let color, _):
            return color.shortCode
        case .tiger:
            return "TGR"
        case .bull:
            return "BUL"
        case .bear:
            return "BER"
        }
    }
}

private extension CardColor {
    var shortCode: String {
        switch self {
        case .red: return "RED"
        case .yellow: return "YEL"
        case .black: return "BLK"
        case .green: return "GRN"
        }
    }
}

/// The scanned card back, used for transient shuffle/deal animation.
struct CardBackFace: View {
    var width: CGFloat = 60
    var height: CGFloat = 85

    private var corner: CGFloat { height * 0.14 }

    var body: some View {
        cardBody
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.24), radius: 5, y: 3)
            .frame(width: width, height: height)
    }

    @ViewBuilder
    private var cardBody: some View {
        if let image = cardBackImage {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white)
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(TableStyle.feltMid)
                .overlay(
                    RoundedRectangle(cornerRadius: corner * 0.7, style: .continuous)
                        .stroke(TableStyle.teamAmber.opacity(0.8), lineWidth: 2)
                        .padding(height * 0.10))
        }
    }

    #if canImport(UIKit)
    private var cardBackImage: UIImage? {
        UIImage(named: "card_back")
    }
    #else
    private var cardBackImage: Never? { nil }
    #endif
}

/// A short decorative shuffle/deal overlay. It is deliberately non-interactive:
/// the game can keep rendering frames while the animation adds table feel.
struct DealingAnimationOverlay: View {
    let trigger: Int
    var cardWidth: CGFloat = 64
    var cardHeight: CGFloat = 90
    var spreadScale: CGFloat = 1.0

    @State private var visible = false
    @State private var shuffling = false
    @State private var dealt = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if visible {
                    ForEach(0..<12, id: \.self) { index in
                        CardBackFace(width: cardWidth, height: cardHeight)
                            .rotationEffect(.degrees(rotation(for: index)))
                            .offset(offset(for: index, in: proxy.size))
                            .opacity(dealt ? 0 : 1)
                            .scaleEffect(dealt ? 0.92 : 1.0)
                    }
                    Text("Dealing")
                        .font(TableTypography.display(.caption, weight: .bold))
                        .foregroundStyle(.white.opacity(dealt ? 0 : 0.70))
                        .offset(y: cardHeight * 0.82)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { restartIfNeeded() }
        .onChange(of: trigger) { _, _ in restartIfNeeded() }
    }

    private func restartIfNeeded() {
        guard trigger >= 0 else { return }
        SoundEffectPlayer.shared.play(.cardShuffle)
        visible = true
        shuffling = false
        dealt = false

        withAnimation(.easeInOut(duration: 0.18).repeatCount(5, autoreverses: true)) {
            shuffling = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) {
            guard visible else { return }
            withAnimation(.easeOut(duration: 0.72)) {
                dealt = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.92) {
            guard visible else { return }
            visible = false
        }
    }

    private func rotation(for index: Int) -> Double {
        if dealt {
            return [-18, 12, -10, 16][index % 4] + Double(index / 4) * 2
        }
        let base = Double(index - 6) * 1.8
        return base + (shuffling ? Double((index % 3) - 1) * 9 : 0)
    }

    private func offset(for index: Int, in size: CGSize) -> CGSize {
        if dealt {
            let lane = index % 4
            let depth = CGFloat(index / 4) * 0.16 + 0.82
            let x = size.width * 0.33 * spreadScale * depth
            let y = size.height * 0.30 * spreadScale * depth
            switch lane {
            case 0: return CGSize(width: 0, height: y)
            case 1: return CGSize(width: -x, height: 0)
            case 2: return CGSize(width: 0, height: -y)
            default: return CGSize(width: x, height: 0)
            }
        }

        let shuffleX = shuffling ? CGFloat((index % 4) - 1) * 5 : CGFloat(index - 6) * 0.6
        let shuffleY = shuffling ? CGFloat((index % 3) - 1) * 3 : CGFloat(index - 6) * 0.4
        return CGSize(width: shuffleX, height: shuffleY)
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
