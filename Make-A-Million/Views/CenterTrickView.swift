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
            cardW: 158, cardH: 222, spread: 176, circle: 520, frame: 650,
            ledDot: 28, idleFont: TableTypography.display(.title2, weight: .bold))

        static let phone = Metrics(
            cardW: 68, cardH: 96, spread: 72, circle: 210, frame: 254,
            ledDot: 17, idleFont: TableTypography.display(.subheadline, weight: .bold))

        static let tablet = Metrics(
            cardW: 146, cardH: 205, spread: 156, circle: 438, frame: 552,
            ledDot: 24, idleFont: TableTypography.display(.title3, weight: .bold))
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
    /// Tiger / Bull / Bear plays burst onto the table. Driven by the
    /// Audiovisual settings toggle; the card itself still flies in normally.
    var showsAnimalCues: Bool = true
    /// When set, the viewer's own card uses matchedGeometryEffect into this
    /// namespace (animating from the fanned hand) instead of an edge fly-in.
    var cardNS: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: SweepState? = nil
    @State private var animalCue: AnimalPlayCue? = nil
    @State private var animalCueID: Int = 0
    @State private var didStampedeCurrentTrick = false

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
        .onChange(of: plays.count) { oldCount, newCount in
            if newCount > oldCount {
                SoundEffectPlayer.shared.play(.cardPlay)
            }
            if newCount <= 1 || newCount < oldCount {
                didStampedeCurrentTrick = false
            }
            triggerCuesForLatestPlay()
        }
        .onChange(of: completedTricks.count) { _, count in
            guard count > 0, let last = lastTrick else { sweep = nil; return }
            SoundEffectPlayer.shared.play(.trickTaken)
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

    private func triggerCuesForLatestPlay() {
        guard showsAnimalCues else { return }
        if triggerBullStampedeIfNeeded() { return }

        triggerAnimalCueForLatestPlay()
    }

    private func triggerAnimalCueForLatestPlay() {
        guard showsAnimalCues,
              let play = plays.last,
              let kind = AnimalPlayKind(card: play.card) else { return }

        triggerAnimalCue(kind: kind, playedOffset: centerOffset(for: play.player))
    }

    @discardableResult
    private func triggerBullStampedeIfNeeded() -> Bool {
        guard !didStampedeCurrentTrick,
              let trick = currentTrick,
              trick.hasActiveBull,
              trick.baseMoneyValue >= 40_000
        else { return false }

        let bullPlay = trick.plays.last { $0.card == .bull } ?? trick.plays.last
        didStampedeCurrentTrick = true
        triggerAnimalCue(
            kind: .bullStampede,
            playedOffset: bullPlay.map { centerOffset(for: $0.player) } ?? .zero)
        return true
    }

    private func triggerAnimalCue(kind: AnimalPlayKind, playedOffset: CGSize) {
        animalCueID &+= 1
        let id = animalCueID
        animalCue = AnimalPlayCue(
            id: id,
            kind: kind,
            playedOffset: playedOffset)

        let duration = kind.displayDuration(reduceMotion: reduceMotion)
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
    case bullStampede

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
        case .tiger: return "animal_tiger"
        case .bull, .bullStampede: return "animal_bull"
        case .bear: return "animal_bear"
        }
    }

    var imageScale: CGFloat {
        switch self {
        case .tiger: return 2.38
        case .bull: return 2.62
        case .bullStampede: return 1.72
        case .bear: return 2.30
        }
    }

    var burstText: String {
        switch self {
        case .tiger: return "TIGER"
        case .bull: return "$ x2"
        case .bullStampede: return "STAMPEDE"
        case .bear: return "$0"
        }
    }

    var tint: Color {
        switch self {
        case .tiger: return Color(red: 1.00, green: 0.61, blue: 0.10)
        case .bull, .bullStampede: return Color(red: 0.95, green: 0.12, blue: 0.10)
        case .bear: return Color(red: 0.66, green: 0.56, blue: 0.43)
        }
    }

    var accent: Color {
        switch self {
        case .tiger: return Color(red: 0.08, green: 0.07, blue: 0.05)
        case .bull, .bullStampede: return Color(red: 1.00, green: 0.94, blue: 0.78)
        case .bear: return Color(red: 0.92, green: 0.95, blue: 0.98)
        }
    }

    var echoOpacity: Double {
        switch self {
        case .tiger: return 0.88
        case .bull: return 0.86
        case .bullStampede: return 0.92
        case .bear: return 0.82
        }
    }

    var echoRotation: Double {
        switch self {
        case .tiger: return -7
        case .bull: return 4
        case .bullStampede: return 0
        case .bear: return -3
        }
    }

    var soundCue: SoundCue {
        switch self {
        case .tiger: return .animalTiger
        case .bull: return .animalBull
        case .bullStampede: return .bullStampede
        case .bear: return .animalBear
        }
    }

    func displayDuration(reduceMotion: Bool) -> Double {
        switch self {
        case .bullStampede: return reduceMotion ? 3.2 : 5.0
        default: return reduceMotion ? 1.0 : 2.0
        }
    }
}

private struct AnimalPlayAnimation: View {
    let cue: AnimalPlayCue
    let metrics: CenterTrickView.Metrics
    let reduceMotion: Bool

    @State private var popped = false
    @State private var fading = false

    var body: some View {
        ZStack {
            if cue.kind == .bullStampede {
                BullStampedeAnimation(
                    metrics: metrics,
                    reduceMotion: reduceMotion,
                    active: popped,
                    fading: fading)
            } else {
                impactBackdrop

                if cue.kind == .bear {
                    bearCancelWash
                }

                impactGlow
                impactRing
                animalEcho

                if !reduceMotion {
                    AnimalImpactLines(kind: cue.kind, metrics: metrics, expanded: popped, fading: fading)
                }

                burstLabel
            }
        }
        .frame(width: metrics.frame, height: metrics.frame)
        .offset(
            x: cue.kind == .bullStampede ? 0 : cue.playedOffset.width * (reduceMotion ? 0.10 : 0.18),
            y: cue.kind == .bullStampede ? 0 : cue.playedOffset.height * (reduceMotion ? 0.10 : 0.18))
        .compositingGroup()
        .onAppear {
            SoundEffectPlayer.shared.play(cue.kind.soundCue)

            if cue.kind == .bullStampede {
                withAnimation(.easeOut(duration: reduceMotion ? 0.18 : 0.32)) {
                    popped = true
                }

                let hold = reduceMotion ? 2.35 : 4.18
                let fadeDuration = reduceMotion ? 0.55 : 0.78
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                    withAnimation(.easeOut(duration: fadeDuration)) {
                        fading = true
                    }
                }
            } else {
                let response = reduceMotion ? 0.24 : 0.34
                withAnimation(.spring(response: response, dampingFraction: 0.72)) {
                    popped = true
                }

                let hold = reduceMotion ? 0.28 : 0.58
                let fadeDuration = reduceMotion ? 0.32 : 0.56
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                    withAnimation(.easeOut(duration: fadeDuration)) {
                        fading = true
                    }
                }
            }
        }
    }

    private var impactBackdrop: some View {
        Circle()
            .fill(Color.black.opacity(cue.kind == .bear ? 0.32 : 0.24))
            .frame(width: metrics.frame * 0.78, height: metrics.frame * 0.78)
            .blur(radius: metrics.cardW * 0.20)
            .scaleEffect(popped ? 1.0 : 0.62)
            .opacity(fading ? 0 : 1)
    }

    private var impactGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        cue.kind.tint.opacity(reduceMotion ? 0.34 : 0.58),
                        cue.kind.tint.opacity(0.26),
                        .clear
                    ],
                    center: .center,
                    startRadius: metrics.cardW * 0.2,
                    endRadius: metrics.frame * 0.48))
            .frame(width: metrics.frame * 0.92, height: metrics.frame * 0.92)
            .scaleEffect(popped ? 1.08 : 0.34)
            .opacity(fading ? 0 : 1)
    }

    private var impactRing: some View {
        Circle()
            .stroke(
                cue.kind.tint.opacity(fading ? 0 : 0.92),
                lineWidth: max(2, metrics.cardW * 0.045))
            .frame(
                width: metrics.frame * (popped ? 0.54 : 0.18),
                height: metrics.frame * (popped ? 0.54 : 0.18))
            .shadow(color: cue.kind.tint.opacity(0.75), radius: metrics.cardW * 0.12)
    }

    private var animalEcho: some View {
        Image(cue.kind.assetName)
            .resizable()
            .scaledToFit()
            .saturation(cue.kind == .bear ? 0.25 : 1.12)
            .contrast(cue.kind == .bear ? 1.10 : 1.24)
            .frame(width: metrics.cardW * cue.kind.imageScale * (reduceMotion ? 0.72 : 1.0))
            .shadow(color: cue.kind.tint.opacity(0.82), radius: metrics.cardW * 0.20)
            .shadow(color: .white.opacity(cue.kind == .bear ? 0.50 : 0.18), radius: metrics.cardW * 0.06)
            .shadow(color: .black.opacity(0.58), radius: metrics.cardW * 0.14, y: metrics.cardW * 0.07)
            .scaleEffect(popped ? 1.0 : 0.58)
            .rotationEffect(.degrees(popped ? cue.kind.echoRotation : 0))
            .opacity(fading ? 0 : cue.kind.echoOpacity)
    }

    private var burstLabel: some View {
        Text(cue.kind.burstText)
            .font(TableTypography.display(size: max(22, metrics.cardH * 0.44), weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, metrics.cardW * 0.18)
            .padding(.vertical, metrics.cardW * 0.07)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.58))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(cue.kind.tint.opacity(0.86), lineWidth: max(1, metrics.cardW * 0.025))
                    }
            }
            .shadow(color: cue.kind.tint.opacity(0.95), radius: metrics.cardW * 0.12, y: 2)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .scaleEffect(popped ? 1.0 : 0.45)
            .offset(y: metrics.cardH * 0.74)
            .opacity(fading ? 0 : 1)
    }

    private var bearCancelWash: some View {
        Circle()
            .fill(Color.white.opacity(0.34))
            .frame(width: metrics.frame * 0.62, height: metrics.frame * 0.62)
            .blur(radius: metrics.cardW * 0.12)
            .scaleEffect(popped ? 1.0 : 0.2)
            .opacity(fading ? 0 : 1)
    }
}

private struct BullStampedeAnimation: View {
    let metrics: CenterTrickView.Metrics
    let reduceMotion: Bool
    let active: Bool
    let fading: Bool

    private let bullCount = 7

    var body: some View {
        ZStack {
            stampedeBackdrop
            dustClouds

            ForEach(0..<bullCount, id: \.self) { index in
                stampedeBull(index: index)
            }

            Text("STAMPEDE")
                .font(TableTypography.display(size: max(26, metrics.cardH * 0.34), weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(.white)
                .padding(.horizontal, metrics.cardW * 0.22)
                .padding(.vertical, metrics.cardW * 0.08)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.64))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color(red: 1.0, green: 0.90, blue: 0.55).opacity(0.95),
                                        lineWidth: max(1, metrics.cardW * 0.026))
                        }
                }
                .shadow(color: Color(red: 0.95, green: 0.12, blue: 0.10).opacity(0.92),
                        radius: metrics.cardW * 0.16)
                .scaleEffect(active ? 1 : 0.58)
                .offset(y: active ? -metrics.cardH * 0.72 : -metrics.cardH * 0.46)
                .opacity(fading ? 0 : 1)
        }
        .opacity(fading ? 0 : 1)
    }

    private var stampedeBackdrop: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.44),
                        Color(red: 0.58, green: 0.12, blue: 0.08).opacity(0.32),
                        Color.black.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing))
            .frame(width: metrics.frame * 0.96, height: metrics.frame * 0.54)
            .blur(radius: metrics.cardW * 0.12)
            .scaleEffect(active ? 1.02 : 0.74)
            .opacity(active ? 1 : 0)
    }

    private var dustClouds: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Circle()
                    .fill(Color(red: 0.85, green: 0.75, blue: 0.58).opacity(index.isMultiple(of: 2) ? 0.30 : 0.20))
                    .frame(
                        width: metrics.cardW * dustScale(for: index),
                        height: metrics.cardW * dustScale(for: index))
                    .blur(radius: metrics.cardW * 0.08)
                    .offset(
                        x: active ? metrics.frame * 0.48 - CGFloat(index) * metrics.cardW * 0.18 : -metrics.frame * 0.44,
                        y: metrics.cardH * dustLane(for: index))
                    .opacity(active && !fading ? 1 : 0)
                    .animation(
                        .easeOut(duration: reduceMotion ? 1.4 : 3.8)
                            .delay(Double(index) * 0.07),
                        value: active)
            }
        }
    }

    private func stampedeBull(index: Int) -> some View {
        Image("animal_bull")
            .resizable()
            .scaledToFit()
            .contrast(1.18)
            .saturation(1.10)
            .frame(width: metrics.cardW * bullWidthMultiplier(for: index))
            .shadow(color: Color(red: 0.95, green: 0.12, blue: 0.10).opacity(0.70),
                    radius: metrics.cardW * 0.13)
            .shadow(color: .black.opacity(0.64), radius: metrics.cardW * 0.12, y: metrics.cardW * 0.06)
            .scaleEffect(active ? 1 : 0.72)
            .rotationEffect(.degrees(rotation(for: index)))
            .offset(
                x: active ? metrics.frame * 0.82 : -metrics.frame * 0.82,
                y: metrics.cardH * lane(for: index))
            .opacity(fading ? 0 : opacity(for: index))
            .animation(
                .easeInOut(duration: reduceMotion ? 1.6 : 3.65)
                    .delay(Double(index) * (reduceMotion ? 0.10 : 0.22)),
                value: active)
    }

    private func lane(for index: Int) -> CGFloat {
        [-0.28, 0.08, 0.34, -0.05, 0.25, -0.20, 0.16][index]
    }

    private func dustLane(for index: Int) -> CGFloat {
        [-0.18, 0.02, 0.24, 0.38, -0.05, 0.18, 0.32, -0.22, 0.08, 0.28, -0.12, 0.40][index]
    }

    private func dustScale(for index: Int) -> CGFloat {
        index.isMultiple(of: 3) ? 0.54 : 0.36
    }

    private func bullWidthMultiplier(for index: Int) -> CGFloat {
        index.isMultiple(of: 3) ? 1.95 : 1.62
    }

    private func rotation(for index: Int) -> Double {
        [-4, 3, -2, 5, -3, 2, 0][index]
    }

    private func opacity(for index: Int) -> Double {
        index.isMultiple(of: 3) ? 0.96 : 0.82
    }
}

private struct AnimalImpactLines: View {
    let kind: AnimalPlayKind
    let metrics: CenterTrickView.Metrics
    let expanded: Bool
    let fading: Bool

    private var lineCount: Int {
        switch kind {
        case .tiger: return 10
        case .bull, .bullStampede: return 12
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
                    .offset(x: expanded ? metrics.frame * 0.26 : metrics.cardW * 0.08)
                    .rotationEffect(.degrees(angle(for: index)))
                    .opacity(fading ? 0 : 0.92)
                    .animation(
                        .easeOut(duration: 0.48)
                            .delay(Double(index) * 0.012),
                        value: expanded)
            }
        }
    }

    private func angle(for index: Int) -> Double {
        let base = 360.0 / Double(lineCount) * Double(index)
        switch kind {
        case .tiger: return base - 18
        case .bull, .bullStampede: return base
        case .bear: return base + 9
        }
    }

    private func lineWidthMultiplier(for index: Int) -> CGFloat {
        switch kind {
        case .tiger: return index.isMultiple(of: 3) ? 0.78 : 0.52
        case .bull, .bullStampede: return index.isMultiple(of: 2) ? 0.92 : 0.64
        case .bear: return 0.56
        }
    }
}
