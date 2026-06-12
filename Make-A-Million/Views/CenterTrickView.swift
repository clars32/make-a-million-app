//
//  CenterTrickView.swift
//  Make-a-Million
//
//  The shared "cards in the middle of the table" surface. Each play sits out
//  toward the seat that made it, flies in from that edge, and the whole trick
//  sweeps out to the winner when it resolves. Factored out of TabletopGameView
//  so the phone-sized board in GameBody (solo / host) shares the exact same
//  geometry and animations and the two surfaces can never drift.
//
//  Two ways it's used:
//   • Tabletop  — absolute seating, seat 0 at the bottom (pass `viewer:
//                 PlayerID(0)`), full-size cards.
//   • GameBody  — viewer-relative: `viewer` (the local player) is rotated to
//                 the bottom, the other three map to left / top / right by
//                 their clockwise offset. A card namespace is supplied so the
//                 local player's own card flies from the fanned hand via
//                 matchedGeometryEffect instead of from the edge.
//

import SwiftUI

struct CenterTrickView: View {

    /// Sizing for a given surface. The phone preset shrinks everything so the
    /// board fits above the fanned hand on a small screen.
    struct Metrics {
        var cardW: CGFloat
        var cardH: CGFloat
        /// How far each card rests from dead center, toward its player's edge.
        var spread: CGFloat
        var circle: CGFloat
        var frame: CGFloat
        var ledDot: CGFloat
        var idleFont: Font

        static let tabletop = Metrics(
            cardW: 150, cardH: 211, spread: 170, circle: 500, frame: 640,
            ledDot: 26, idleFont: TableTypography.display(.title2, weight: .bold))

        static let phone = Metrics(
            cardW: 64, cardH: 90, spread: 68, circle: 200, frame: 244,
            ledDot: 16, idleFont: TableTypography.display(.subheadline, weight: .bold))

        static let tablet = Metrics(
            cardW: 136, cardH: 191, spread: 146, circle: 410, frame: 520,
            ledDot: 22, idleFont: TableTypography.display(.title3, weight: .bold))
    }

    let currentTrick: Trick?
    let completedTricks: [CompletedTrickInfo]
    let trump: CardColor?
    /// The seat rendered at the bottom edge. Every other seat's direction is
    /// computed relative to this one, so the board reads from this player's POV.
    let viewer: PlayerID
    var metrics: Metrics = .tabletop
    let seatName: (PlayerID) -> String
    /// Show the "X won $Yk" / "Waiting for the lead…" text when the center is
    /// empty. Tabletop wants it; tight phone layouts can switch it off.
    var showsIdleText: Bool = true
    /// When set, the viewer's own card uses matchedGeometryEffect into this
    /// namespace (animating from the fanned hand) instead of an edge fly-in.
    var cardNS: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: SweepState? = nil
    @State private var animalCue: AnimalPlayCue? = nil
    @State private var animalCueID: Int = 0

    /// A just-completed trick animating out toward its winner.
    private struct SweepState: Equatable {
        let index: Int
        let plays: [PlayedCard]
        let winner: PlayerID
        var arrived: Bool
    }

    private var plays: [PlayedCard] { currentTrick?.plays ?? [] }
    private var lastTrick: CompletedTrickInfo? { completedTricks.last }

    var body: some View {
        let idle = plays.isEmpty && sweep == nil
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.035))
                .overlay(Circle().stroke(Color.white.opacity(0.055), lineWidth: 1))
                .frame(width: metrics.circle, height: metrics.circle)

            // Led-suit reminder at dead center (cards rest out toward the edges).
            if let trump,
               let led = currentTrick?.ledColor(trump: trump),
               !plays.isEmpty {
                VStack(spacing: 3) {
                    Circle().fill(colorSwatch(led))
                        .frame(width: metrics.ledDot, height: metrics.ledDot)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    Text("Led").font(TableTypography.display(.caption2)).foregroundStyle(.white.opacity(0.66))
                }
            }

            // In-progress trick — each card flies in from its player's side.
            ForEach(keyedPlays(plays), id: \.key) { entry in
                trickCard(entry.play)
            }

            // Just-completed trick sweeping out to the winner.
            if let s = sweep {
                ForEach(keyedPlays(s.plays), id: \.key) { entry in
                    cardFace(entry.play.card)
                        .offset(s.arrived ? sweptOffset(for: s.winner)
                                          : centerOffset(for: entry.play.player))
                        .opacity(s.arrived ? 0 : 1)
                }
            }

            if let cue = animalCue {
                AnimalPlayAnimation(cue: cue, metrics: metrics, reduceMotion: reduceMotion)
                    .id(cue.id)
                    .allowsHitTesting(false)
            }

            if idle && showsIdleText {
                if let last = lastTrick {
                    Text("\(seatName(last.winner)) won $\(last.value / 1000)k")
                        .font(metrics.idleFont)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                } else {
                    Text("Waiting for the lead…")
                        .font(metrics.idleFont)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: metrics.frame, height: metrics.frame)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: plays.count)
        .onChange(of: plays.count) { _, _ in
            triggerAnimalCueForLatestPlay()
        }
        .onChange(of: completedTricks.count) { _, count in
            guard count > 0, let last = lastTrick else { sweep = nil; return }
            startSweep(last, index: count)
        }
    }

    /// The viewer's own card animates from the hand (matchedGeometry); the
    /// others fly in from their edge.
    @ViewBuilder
    private func trickCard(_ play: PlayedCard) -> some View {
        if let ns = cardNS, play.player == viewer {
            cardFace(play.card)
                .offset(centerOffset(for: play.player))
                .matchedGeometryEffect(id: cardKey(play.card), in: ns)
        } else {
            cardFace(play.card)
                .offset(centerOffset(for: play.player))
                .transition(flyIn(for: play.player))
        }
    }

    private func cardFace(_ card: Card) -> some View {
        CardFace(card: card, width: metrics.cardW, height: metrics.cardH)
            .shadow(color: .black.opacity(0.24), radius: 7, y: 5)
    }

    /// Animate the four just-played cards toward the winner, then clear.
    private func startSweep(_ last: CompletedTrickInfo, index: Int) {
        sweep = SweepState(index: index, plays: last.plays, winner: last.winner, arrived: false)
        withAnimation(.easeIn(duration: 0.55)) {
            sweep?.arrived = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if sweep?.index == index { sweep = nil }
        }
    }

    private func triggerAnimalCueForLatestPlay() {
        guard let play = plays.last,
              let kind = AnimalPlayKind(card: play.card) else { return }

        animalCueID &+= 1
        let id = animalCueID
        animalCue = AnimalPlayCue(
            id: id,
            kind: kind,
            playedOffset: centerOffset(for: play.player))

        let duration = reduceMotion ? 0.42 : 0.95
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if animalCue?.id == id {
                animalCue = nil
            }
        }
    }

    // MARK: - Seat-relative geometry

    /// Clockwise offset of `seat` from the viewer: 0 bottom, 1 left, 2 top, 3 right.
    private func direction(for seat: PlayerID) -> Int {
        (seat.raw - viewer.raw + Seats.count) % Seats.count
    }

    /// Where a seat's card rests relative to center (toward that seat's edge).
    private func centerOffset(for seat: PlayerID) -> CGSize {
        switch direction(for: seat) {
        case 0: return CGSize(width: 0, height: metrics.spread)    // bottom (viewer)
        case 1: return CGSize(width: -metrics.spread, height: 0)   // left
        case 2: return CGSize(width: 0, height: -metrics.spread)   // top
        case 3: return CGSize(width: metrics.spread, height: 0)    // right
        default: return .zero
        }
    }

    /// Off-table position toward a seat — the sweep-out destination.
    private func sweptOffset(for seat: PlayerID) -> CGSize {
        let c = centerOffset(for: seat)
        return CGSize(width: c.width * 2.8, height: c.height * 2.8)
    }

    /// Insertion transition: slide in from the player's edge; instant removal
    /// (the sweep overlay handles the visible exit).
    private func flyIn(for seat: PlayerID) -> AnyTransition {
        let c = centerOffset(for: seat)
        let delta = CGSize(width: c.width * 1.8, height: c.height * 1.8)
        return .asymmetric(
            insertion: .offset(delta).combined(with: .opacity),
            removal: .identity)
    }

    private func colorSwatch(_ color: CardColor) -> Color {
        TableStyle.suitSwatch(color)
    }
}

private struct AnimalPlayCue: Equatable, Identifiable {
    let id: Int
    let kind: AnimalPlayKind
    let playedOffset: CGSize
}

private enum AnimalPlayKind: Equatable {
    case tiger
    case bull
    case bear

    init?(card: Card) {
        switch card {
        case .tiger: self = .tiger
        case .bull: self = .bull
        case .bear: self = .bear
        case .colored: return nil
        }
    }

    var assetName: String {
        switch self {
        case .tiger: return "card_tiger"
        case .bull: return "card_bull"
        case .bear: return "card_bear"
        }
    }

    var burstText: String {
        switch self {
        case .tiger: return "TIGER"
        case .bull: return "$ x2"
        case .bear: return "$0"
        }
    }

    var tint: Color {
        switch self {
        case .tiger: return Color(red: 1.00, green: 0.61, blue: 0.10)
        case .bull: return Color(red: 0.95, green: 0.12, blue: 0.10)
        case .bear: return Color(red: 0.66, green: 0.56, blue: 0.43)
        }
    }

    var accent: Color {
        switch self {
        case .tiger: return Color(red: 0.08, green: 0.07, blue: 0.05)
        case .bull: return Color(red: 1.00, green: 0.94, blue: 0.78)
        case .bear: return Color(red: 0.92, green: 0.95, blue: 0.98)
        }
    }

    var echoOpacity: Double {
        switch self {
        case .tiger: return 0.24
        case .bull: return 0.22
        case .bear: return 0.20
        }
    }

    var echoRotation: Double {
        switch self {
        case .tiger: return -7
        case .bull: return 4
        case .bear: return -3
        }
    }
}

private struct AnimalPlayAnimation: View {
    let cue: AnimalPlayCue
    let metrics: CenterTrickView.Metrics
    let reduceMotion: Bool

    @State private var active = false

    var body: some View {
        ZStack {
            if cue.kind == .bear {
                bearCancelWash
            }

            impactGlow
            animalEcho

            if !reduceMotion {
                AnimalImpactLines(kind: cue.kind, metrics: metrics, active: active)
            }

            burstLabel
        }
        .frame(width: metrics.frame, height: metrics.frame)
        .offset(
            x: cue.playedOffset.width * (reduceMotion ? 0.16 : 0.28),
            y: cue.playedOffset.height * (reduceMotion ? 0.16 : 0.28))
        .compositingGroup()
        .onAppear {
            let response = reduceMotion ? 0.24 : 0.44
            withAnimation(.spring(response: response, dampingFraction: 0.72)) {
                active = true
            }
        }
    }

    private var impactGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        cue.kind.tint.opacity(reduceMotion ? 0.26 : 0.38),
                        cue.kind.tint.opacity(0.14),
                        .clear
                    ],
                    center: .center,
                    startRadius: metrics.cardW * 0.2,
                    endRadius: metrics.frame * 0.48))
            .frame(width: metrics.frame * 0.92, height: metrics.frame * 0.92)
            .scaleEffect(active ? 1.12 : 0.36)
            .opacity(active ? 0 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.34 : 0.78), value: active)
    }

    private var animalEcho: some View {
        Image(cue.kind.assetName)
            .resizable()
            .scaledToFit()
            .saturation(cue.kind == .bear ? 0.25 : 1.12)
            .contrast(cue.kind == .bear ? 1.05 : 1.18)
            .frame(width: metrics.cardW * (reduceMotion ? 1.55 : 2.85))
            .scaleEffect(active ? 1.16 : 0.64)
            .rotationEffect(.degrees(active ? cue.kind.echoRotation : 0))
            .opacity(active ? 0 : cue.kind.echoOpacity)
            .blendMode(cue.kind == .bear ? .normal : .screen)
            .animation(.easeOut(duration: reduceMotion ? 0.34 : 0.72), value: active)
    }

    private var burstLabel: some View {
        Text(cue.kind.burstText)
            .font(TableTypography.display(size: max(18, metrics.cardH * 0.38), weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .shadow(color: cue.kind.tint.opacity(0.95), radius: 8, y: 2)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            .scaleEffect(active ? 1.0 : 0.45)
            .opacity(active ? 0 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.32 : 0.64).delay(0.08), value: active)
    }

    private var bearCancelWash: some View {
        Circle()
            .fill(Color.white.opacity(0.16))
            .frame(width: metrics.frame * 0.58, height: metrics.frame * 0.58)
            .blur(radius: metrics.cardW * 0.12)
            .scaleEffect(active ? 1.0 : 0.2)
            .opacity(active ? 0 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.28 : 0.58), value: active)
    }
}

private struct AnimalImpactLines: View {
    let kind: AnimalPlayKind
    let metrics: CenterTrickView.Metrics
    let active: Bool

    private var lineCount: Int {
        switch kind {
        case .tiger: return 10
        case .bull: return 12
        case .bear: return 8
        }
    }

    var body: some View {
        ZStack {
            ForEach(0..<lineCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index.isMultiple(of: 2) ? kind.tint : kind.accent)
                    .frame(
                        width: metrics.cardW * lineWidthMultiplier(for: index),
                        height: max(2, metrics.cardW * 0.035))
                    .offset(x: active ? metrics.frame * 0.24 : metrics.cardW * 0.15)
                    .rotationEffect(.degrees(angle(for: index)))
                    .opacity(active ? 0 : 0.78)
                    .animation(
                        .easeOut(duration: 0.48)
                            .delay(Double(index) * 0.012),
                        value: active)
            }
        }
    }

    private func angle(for index: Int) -> Double {
        let base = 360.0 / Double(lineCount) * Double(index)
        switch kind {
        case .tiger: return base - 18
        case .bull: return base
        case .bear: return base + 9
        }
    }

    private func lineWidthMultiplier(for index: Int) -> CGFloat {
        switch kind {
        case .tiger: return index.isMultiple(of: 3) ? 0.78 : 0.52
        case .bull: return index.isMultiple(of: 2) ? 0.92 : 0.64
        case .bear: return 0.56
        }
    }
}
