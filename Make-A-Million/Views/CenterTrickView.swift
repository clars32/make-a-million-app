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
            cardW: 82, cardH: 115, spread: 104, circle: 300, frame: 380,
            ledDot: 22, idleFont: .system(.title3, design: .rounded).bold())

        static let phone = Metrics(
            cardW: 64, cardH: 90, spread: 68, circle: 200, frame: 244,
            ledDot: 16, idleFont: .system(.subheadline, design: .rounded).bold())

        static let tablet = Metrics(
            cardW: 136, cardH: 191, spread: 146, circle: 410, frame: 520,
            ledDot: 22, idleFont: .system(.title3, design: .rounded).bold())
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

    @State private var sweep: SweepState? = nil

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
                .fill(Color.white.opacity(0.04))
                .frame(width: metrics.circle, height: metrics.circle)

            // Led-suit reminder at dead center (cards rest out toward the edges).
            if let trump,
               let led = currentTrick?.ledColor(trump: trump),
               !plays.isEmpty {
                VStack(spacing: 3) {
                    Circle().fill(colorSwatch(led))
                        .frame(width: metrics.ledDot, height: metrics.ledDot)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    Text("Led").font(.caption2).foregroundStyle(.white.opacity(0.6))
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
            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
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
        color == .black ? .black : color.swatch
    }
}
