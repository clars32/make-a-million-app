//
//  ClientGameView.swift
//  Make-a-Million
//
//  The player's phone. Held in landscape like a real hand of cards: the screen
//  is just the fanned hand. All shared/public information (scores, trump, the
//  trick in play, whose turn it is) lives on the tabletop, not here.
//
//  Idle = cards only. When it's this player's turn:
//   • trick play   — legal cards highlight and are tappable to play.
//   • bid / trump / discard — a compact action bar slides up over the hand,
//     then collapses back to cards-only once the move is made.
//

import SwiftUI

struct ClientGameView: View {

    let playerName: String
    let hostName: String
    @ObservedObject var session: ClientSession
    let onExit: () -> Void

    @State private var lastView: PlayerView? = nil
    @State private var discardSelection: Set<Card> = []
    @State private var selectedBidIndex: Int = 0
    @Namespace private var cardNS

    // Card sizing for a phone held in landscape.
    private let cardW: CGFloat = 110
    private let cardH: CGFloat = 156

    /// The view to render. `pending` (a decision frame) takes priority so legal
    /// moves are accurate on this player's turn; otherwise the paced frame.
    private var tableView: PlayerView? {
        session.pending ?? session.displayView ?? lastView
    }
    private var decisionView: PlayerView? {
        session.pending ?? session.displayView ?? lastView
    }
    private var handView: PlayerView? { decisionView }
    private var isMyTurn: Bool { session.pending != nil }

    private var displayTick: Int {
        guard let d = session.displayView else { return -1 }
        return GameBody.animationToken(d)
    }
    private var pendingTick: Int {
        guard let p = session.pending else { return -1 }
        return GameBody.animationToken(p)
    }

    var body: some View {
        ZStack {
            switch session.isTabletopMode {
            case .some(true):
                tabletopClientBody
            case .some(false):
                phoneGameBody
            case .none:
                feltBackground
                waitingView
            }

            topBar

            if case .paused(let reason) = session.phase {
                pausedOverlay(reason: reason)
            } else if session.phase == .disconnected {
                disconnectedOverlay
            }
        }
        .onAppear {
            setOrientationForMode()
            lastView = tableView
        }
        .onDisappear { setOrientation(.portrait) }
        .onChange(of: session.isTabletopMode) { _, _ in
            setOrientationForMode()
        }
        .onChange(of: displayTick) { _, _ in
            guard let d = session.displayView else { return }
            DispatchQueue.main.async { lastView = d }
        }
        .onChange(of: pendingTick) { _, _ in
            // New decision arrived — clear any stale discard selection.
            DispatchQueue.main.async {
                discardSelection = []
                if session.pending?.phase == .bidding { selectedBidIndex = 0 }
            }
        }
    }

    @ViewBuilder
    private var tabletopClientBody: some View {
        ZStack {
            feltBackground

            if let view = handView {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if isMyTurn { actionBar(view) }   // only for bid/trump/discard
                    handArea(view)
                }
                .padding(.bottom, 6)
            } else {
                waitingView
            }

            DealingAnimationOverlay(
                trigger: dealAnimationToken(for: handView),
                cardWidth: 62,
                cardHeight: 88,
                spreadScale: 0.58)
            .padding(.horizontal, 26)
            .padding(.bottom, cardH * 0.35)
            .zIndex(2)
        }
        .onAppear { setOrientation(.landscape) }
    }

    private var phoneGameBody: some View {
        GameBody(
            tableView: tableView,
            decisionView: decisionView ?? tableView,
            isInteractive: isMyTurn,
            caughtUp: session.caughtUp,
            endOfHandSnapshot: nil,
            pendingTick: pendingTick,
            displayTick: displayTick,
            seatNames: clientSeatNames,
            submit: { move in session.submit(move) },
            dealAnother: nil,
            onCaptureLastView: { lastView = $0 })
        .onAppear { setOrientation(.portrait) }
    }

    private var clientSeatNames: [String] {
        var names = session.seatNames
        if names.count != Seats.count {
            names = ["South", "West", "North", "East"]
        }
        if let seat = session.mySeat, names.indices.contains(seat.raw) {
            names[seat.raw] = "You"
        }
        return names
    }

    // MARK: - Hand

    private func handArea(_ view: PlayerView) -> some View {
        FannedHand(cards: view.myHand,
                   cardWidth: cardW,
                   rotationPad: 136,
                   preferredOverlap: cardW * 0.54,
                   outerDip: 16,
                   liftedCards: discardSelection) { card, total in
            handCard(card, view: view, total: total)
        }
        .frame(height: cardH + 74)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func handCard(_ card: Card, view: PlayerView, total: Int) -> some View {
        let playable = isMyTurn && view.phase == .trickPlay && isLegalPlay(card, in: view)
        let selectable = isMyTurn && view.phase == .widowDiscard && isDiscardSelectable(card, in: view)
        let selected = discardSelection.contains(card)

        Group {
            if playable {
                Button { session.submit(.play(card)) } label: {
                    CardFace(card: card, highlighted: true,
                             width: cardW, height: cardH, dense: total > 12)
                }
                .buttonStyle(.plain)
            } else if selectable {
                Button { toggleDiscard(card) } label: {
                    CardFace(card: card, selected: selected, highlighted: true,
                             width: cardW, height: cardH, dense: total > 12)
                }
                .buttonStyle(.plain)
            } else {
                CardFace(card: card, selected: selected,
                         width: cardW, height: cardH, dense: total > 12)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: - Action bar (bid / trump / discard only)

    @ViewBuilder
    private func actionBar(_ view: PlayerView) -> some View {
        switch view.phase {
        case .bidding:      biddingBar(view)
        case .namingTrump:  trumpBar(view)
        case .widowDiscard: discardBar(view)
        default:            EmptyView()
        }
    }

    private func biddingBar(_ view: PlayerView) -> some View {
        let passMove = view.legalMoves.first { $0.isPass }
        let bidMoves = view.legalMoves.filter { $0.bidAmount != nil }
        let bidAmounts = bidMoves.compactMap(\.bidAmount)
        let safeIndex = min(selectedBidIndex, max(0, bidMoves.count - 1))
        let bidSelection = Binding<Int>(
            get: { min(selectedBidIndex, max(0, bidMoves.count - 1)) },
            set: { selectedBidIndex = $0 }
        )

        return HStack(spacing: 10) {
            if !bidMoves.isEmpty {
                BidAmountWheel(
                    amounts: bidAmounts,
                    selection: bidSelection,
                    width: 102,
                    height: 76,
                    rowHeight: 24,
                    textStyle: .headline)
            }

            HStack(spacing: 8) {
                if !bidMoves.isEmpty {
                    actionButton("Bid", tint: TableStyle.actionBlue) {
                        session.submit(bidMoves[safeIndex])
                    }
                }
                if let passMove {
                    actionButton("Pass", tint: TableStyle.passGray.opacity(0.82)) {
                        session.submit(passMove)
                    }
                }
            }
        }
        .barChrome()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func trumpBar(_ view: PlayerView) -> some View {
        let trumpMoves: [(CardColor, Move)] = view.legalMoves.compactMap { move in
            if case .nameTrump(let c) = move { return (c, move) }
            return nil
        }
        return HStack(spacing: 10) {
            Text("Trump:").font(TableTypography.display(.subheadline, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            ForEach(trumpMoves, id: \.0) { color, move in
                let swatch = TableStyle.suitSwatch(color)
                Button { session.submit(move) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(swatch).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        Text(color.displayName).font(TableTypography.display(.subheadline, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Capsule().fill(swatch.opacity(color == .black ? 0.68 : 0.76)))
                    .overlay(Capsule().stroke(swatch.opacity(0.90), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .barChrome()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func discardBar(_ view: PlayerView) -> some View {
        let ready = discardSelection.count == 3
        let move = ready ? matchingDiscardMove(in: view) : nil
        return HStack(spacing: 12) {
            Text("Discard 3 — tap your cards")
                .font(TableTypography.display(.subheadline, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text("\(discardSelection.count)/3")
                .font(TableTypography.money(.subheadline))
                .foregroundStyle(.white)
            actionButton("Discard", tint: move == nil ? TableStyle.passGray.opacity(0.82) : TableStyle.actionBlue) {
                if let move { session.submit(move); discardSelection = [] }
            }
            .disabled(move == nil)
            .opacity(move == nil ? 0.5 : 1)
        }
        .barChrome()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TableTypography.display(.subheadline, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(tint))
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chrome

    private var feltBackground: some View {
        TableFeltBackground()
    }

    private var topBar: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    session.stop()
                    onExit()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(TableTypography.display(.subheadline, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(TableStyle.panelStroke, lineWidth: 1))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.3)
            Text("Waiting for the table…")
                .font(TableTypography.display(.callout)).foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Overlays

    private func pausedOverlay(reason: PauseReason) -> some View {
        overlayCard {
            Image(systemName: "pause.circle.fill").font(.system(size: 48)).foregroundStyle(TableStyle.teamAmber)
            Text("Table paused").font(TableTypography.display(.title3, weight: .bold)).foregroundStyle(.white)
            Text(messageFor(reason)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.68))
            Text("Waiting for the host…").font(TableTypography.display(.caption)).foregroundStyle(.white.opacity(0.42)).padding(.top, 4)
        }
    }

    private var disconnectedOverlay: some View {
        overlayCard {
            Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundStyle(TableStyle.teamAmber)
            Text("Disconnected").font(TableTypography.display(.title3, weight: .bold)).foregroundStyle(.white)
            Text("Lost connection to the host.").foregroundStyle(.white.opacity(0.68))
            Button("Back to menu") { session.stop(); onExit() }
                .buttonStyle(.borderedProminent)
                .tint(TableStyle.actionBlue)
                .padding(.top, 6)
        }
    }

    private func overlayCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) { content() }
                .padding(24)
                .tablePanel(cornerRadius: 18, shadowOpacity: 0.34)
                .padding(.horizontal, 40)
        }
    }

    private func messageFor(_ reason: PauseReason) -> String {
        switch reason {
        case .playerDisconnected(_, let name): return "\(name) lost connection."
        }
    }

    // MARK: - Move helpers

    private func isLegalPlay(_ card: Card, in view: PlayerView) -> Bool {
        view.legalMoves.contains { if case .play(let c) = $0 { return c == card }; return false }
    }

    private func matchingDiscardMove(in view: PlayerView) -> Move? {
        view.legalMoves.first { move in
            guard case .discardWidow(let cards) = move else { return false }
            return Set(cards) == discardSelection
        }
    }

    private func toggleDiscard(_ card: Card) {
        if discardSelection.contains(card) { discardSelection.remove(card) }
        else if discardSelection.count < 3 { discardSelection.insert(card) }
    }

    /// Mirror of GameBody.isDiscardSelectable — keeps the UI from offering taps
    /// the engine would reject. (Tier order: plain fills first, then trump —
    /// announced by count — then money, which is shown face-up.)
    private func isDiscardSelectable(_ card: Card, in view: PlayerView) -> Bool {
        guard view.phase == .widowDiscard else { return false }
        if card.isSpecial { return false }
        let plainPool = view.myHand.filter { candidate in
            guard !candidate.isSpecial, !candidate.isMoney else { return false }
            if let trump = view.trump { return candidate.effectiveColor(trump: trump) != trump }
            return true
        }
        if card.isMoney {
            let trumpPool = view.myHand.filter { candidate in
                guard let trump = view.trump else { return false }
                return !candidate.isSpecial && !candidate.isMoney
                    && candidate.effectiveColor(trump: trump) == trump
            }
            return plainPool.count + trumpPool.count < 3
        }
        if let trump = view.trump, card.effectiveColor(trump: trump) == trump {
            return plainPool.count < 3
        }
        return true
    }

    // MARK: - Orientation

    private func setOrientationForMode() {
        setOrientation(session.isTabletopMode == true ? .landscape : .portrait)
    }

    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        OrientationLock.shared.lock(mask)
        DispatchQueue.main.async {
            OrientationLock.shared.lock(mask)
        }
    }
}

private extension View {
    /// Shared pill chrome for the compact action bar.
    func barChrome() -> some View {
        self
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay { Capsule().fill(TableStyle.panelFill) }
            }
            .overlay(Capsule().stroke(TableStyle.panelStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }
}
