//
//  GameView+Board.swift
//  Make-a-Million
//
//  Board, header badges, seat chips, layout metrics, footer, and hand.
//  Split out of GameView.swift; same type via `extension GameBody`.
//

import SwiftUI

extension GameBody {

    @ViewBuilder
    func handCard(_ card: Card, decision: PlayerView, interactive: Bool, totalCards: Int) -> some View {
        let playable = isPlayable(card, in: decision)
        let discardSelectable = isDiscardSelectable(card, in: decision)
        let selected = discardSelection.contains(card)

        Group {
            if interactive && decision.phase == .trickPlay && playable {
                Button { submit(.play(card)) } label: {
                    cardChip(card, faded: false, selected: false, highlighted: true, totalCards: totalCards)
                }
                .buttonStyle(.plain)
            } else if interactive && decision.phase == .widowDiscard && discardSelectable {
                Button {
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    toggleDiscardSelection(card)
                } label: {
                    cardChip(card, faded: false, selected: selected, highlighted: true, totalCards: totalCards)
                }
                .buttonStyle(.plain)
            } else {
                // No fade for non-discardable cards — the green border on
                // legal ones is enough to convey legality, same affordance
                // as during trick play.
                cardChip(card, faded: false, selected: selected, totalCards: totalCards)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: Score bar

    // MARK: Board header (scores + phase + trump / high bid)

    func boardHeader(_ table: PlayerView,
                             decision: PlayerView,
                             interactive: Bool) -> some View {
        let status = phaseStatus(table: table,
                                 decision: decision,
                                 interactive: interactive)
        let scoreMinHeight = boardHeaderCenterHeight > 0 ? boardHeaderCenterHeight : nil
        return HStack(alignment: .top, spacing: isTabletLayout ? 14 : 6) {
            teamScorePill(team: 0, table, minHeight: scoreMinHeight)
            VStack(spacing: 6) {
                Text(table.phase.headline)
                    .font(TableTypography.display(isTabletLayout ? .title2 : .headline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                headerBadges(table)
                if let status {
                    phaseStatusBadge(status)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BoardHeaderCenterHeightKey.self,
                                           value: proxy.size.height)
                }
            }
            teamScorePill(team: 1, table, minHeight: scoreMinHeight)
        }
        .onPreferenceChange(BoardHeaderCenterHeightKey.self) { height in
            guard height > 0, abs(boardHeaderCenterHeight - height) > 0.5 else { return }
            boardHeaderCenterHeight = height
        }
    }

    func phaseStatus(table: PlayerView,
                             decision: PlayerView,
                             interactive: Bool)
    -> (title: String, detail: String?, icon: String, tint: Color)? {
        if interactive {
            switch decision.phase {
            case .bidding:
                return ("Your bid", "Pick amount or pass", "hand.raised.fill", TableStyle.tableGold)
            case .namingTrump:
                return ("Your call", "Choose trump", "paintpalette.fill", TableStyle.cardSelected)
            case .widowDiscard:
                return ("Your discard", "\(discardSelection.count)/3 selected", "tray.and.arrow.down.fill", TableStyle.tableGold)
            case .trickPlay:
                return ("Your turn", "Play highlighted card", "rectangle.stack.fill", TableStyle.cardPlayable)
            case .misdealDecision:
                return ("Your vote", "Redeal or keep hand", "arrow.triangle.2.circlepath", TableStyle.teamAmber)
            case .handComplete:
                return nil
            }
        }

        guard isLivePhase(table.phase) else { return nil }
        return (caughtUp ? "Waiting on \(seatName(table.toAct))" : "Watching play",
                nil,
                "hourglass",
                TableStyle.passGray)
    }

    @ViewBuilder
    func phaseStatusBadge(
        _ status: (title: String, detail: String?, icon: String, tint: Color)
    ) -> some View {
        if isTabletLayout {
            HStack(spacing: 7) {
                Image(systemName: status.icon)
                    .font(TableTypography.display(.caption, weight: .bold))
                Text(status.title)
                    .font(TableTypography.display(.callout, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                if let detail = status.detail {
                    Text(detail)
                        .font(TableTypography.display(.caption))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .layoutPriority(2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.tint.opacity(0.20)))
            .overlay(Capsule().stroke(status.tint.opacity(0.58), lineWidth: 1))
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: status.icon)
                    .font(TableTypography.display(.caption, weight: .bold))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.title)
                        .font(TableTypography.display(.caption, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    if let detail = status.detail {
                        Text(detail)
                            .font(TableTypography.display(.caption2))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.tint.opacity(0.20)))
            .overlay(Capsule().stroke(status.tint.opacity(0.58), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    func headerBadges(_ table: PlayerView) -> some View {
        if table.trump == nil, let bid = table.highBid, let bidder = table.highBidder {
            HStack {
                Spacer(minLength: 0)
                bidBadge(bidder: bidder, amount: bid)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: isTabletLayout ? 10 : 6) {
                if let t = table.trump { trumpBadge(t) }
                if let bid = table.highBid, let bidder = table.highBidder {
                    bidBadge(bidder: bidder, amount: bid)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    func teamScorePill(team: Int,
                               _ table: PlayerView,
                               minHeight: CGFloat? = nil) -> some View {
        let tint = TableStyle.teamTint(team)
        let isMine = Seats.team(of: table.me) == team
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        // "Show live scores" off: hide the running hand total (captured
        // tricks stay face-down at a real table); the settled match score
        // still shows.
        return VStack(alignment: .leading, spacing: isTabletLayout ? 4 : 2) {
            Text(team == 0 ? teamAName : teamBName)
                .font(TableTypography.display(isTabletLayout ? .callout : .caption2, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(settings.showLiveScores ? "$\(hand / 1000)k" : "$\(match / 1000)k")
                .font(TableTypography.money(isTabletLayout ? .title3 : .callout))
                .foregroundStyle(.white)
            if settings.showLiveScores {
                Text("$\(match / 1000)k")
                    .font(TableTypography.money(isTabletLayout ? .callout : .caption2, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, isTabletLayout ? 16 : 9)
        .padding(.vertical, isTabletLayout ? 12 : 7)
        .frame(width: isTabletLayout ? 142 : 88, alignment: .leading)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
                        .fill(tint.opacity(isMine ? 0.18 : 0.10))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: isTabletLayout ? 16 : 12, style: .continuous)
            .stroke(tint.opacity(isMine ? 0.82 : 0.42), lineWidth: isMine ? 2 : 1))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    func trumpBadge(_ color: CardColor) -> some View {
        let swatch = TableStyle.suitSwatch(color)
        return HStack(spacing: isTabletLayout ? 8 : 5) {
            Circle().fill(swatch)
                .frame(width: isTabletLayout ? 18 : 12,
                       height: isTabletLayout ? 18 : 12)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text(color.displayName)
                .font(TableTypography.display(isTabletLayout ? .headline : .caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, isTabletLayout ? 14 : 9)
        .padding(.vertical, isTabletLayout ? 7 : 4)
        .background(Capsule().fill(swatch.opacity(color == .black ? 0.34 : 0.22)))
        .overlay(Capsule().stroke(swatch.opacity(0.68), lineWidth: 1))
        .accessibilityLabel("Trump: \(color.displayName)")
    }

    func bidBadge(bidder: PlayerID, amount: Int) -> some View {
        HStack(spacing: isTabletLayout ? 7 : 4) {
            Image(systemName: "crown.fill")
                .font(isTabletLayout ? .subheadline : .caption2)
                .foregroundStyle(TableStyle.tableGold)
            Text("\(seatShort(bidder)) $\(amount / 1000)k")
                .font(TableTypography.display(isTabletLayout ? .headline : .caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, isTabletLayout ? 14 : 9)
        .padding(.vertical, isTabletLayout ? 7 : 4)
        .background(Capsule().fill(TableStyle.tableGold.opacity(0.18)))
        .overlay(Capsule().stroke(TableStyle.tableGold.opacity(0.58), lineWidth: 1))
    }

    // MARK: Board (opponent seats + center trick)

    func boardArea(_ table: PlayerView,
                           showLiveCards: Bool = true,
                           showsIdleText: Bool = true,
                           dealAnimationTrigger: Int? = nil) -> some View {
        let metrics = soloBoardMetrics
        return ZStack {
            ZStack {
                CenterTrickView(
                    currentTrick: showLiveCards ? table.currentTrick : nil,
                    completedTricks: showLiveCards ? table.completedTricks : [],
                    trump: table.trump,
                    viewer: table.me,
                    metrics: metrics,
                    seatName: seatName,
                    showsIdleText: showsIdleText,
                    showsAnimalCues: settings.animalAnimations,
                    cardNS: showLiveCards ? cardNS : nil)

                if let dealAnimationTrigger {
                    DealingAnimationOverlay(
                        trigger: dealAnimationTrigger,
                        cardWidth: isTabletLayout ? 96 : 68,
                        cardHeight: isTabletLayout ? 135 : 96,
                        spreadScale: isTabletLayout ? 0.66 : 0.60)
                    .frame(width: metrics.frame, height: metrics.frame)
                }
            }

            // All four seats are marked, relative to the local player: bottom
            // (you), left, top (partner), right — mirroring the tabletop board.
            seatChip(relativeSeat(2, from: table.me), table)
                .offset(seatChipOffset(direction: 2))
            seatChip(table.me, table)
                .offset(seatChipOffset(direction: 0))
            seatChip(relativeSeat(1, from: table.me), table)
                .offset(seatChipOffset(direction: 1))
            seatChip(relativeSeat(3, from: table.me), table)
                .offset(seatChipOffset(direction: 3))
        }
        .frame(maxWidth: .infinity)
        .frame(height: soloBoardHeight)
    }

    func seatChipOffset(direction: Int) -> CGSize {
        let distance = soloBoardSeatDistance
        switch direction {
        case 0: return CGSize(width: 0, height: distance)
        case 1: return CGSize(width: -distance, height: 0)
        case 2: return CGSize(width: 0, height: -distance)
        case 3: return CGSize(width: distance, height: 0)
        default: return .zero
        }
    }

    var isTabletLayout: Bool {
        horizontalSizeClass == .regular
    }

    var soloBoardMetrics: CenterTrickView.Metrics {
        isTabletLayout ? .tablet : .phone
    }

    var soloBoardHeight: CGFloat {
        isTabletLayout ? 640 : 320
    }

    var soloBoardSeatDistance: CGFloat {
        isTabletLayout ? 296 : 154
    }

    var miniCardWidth: CGFloat {
        isTabletLayout ? 76 : 38
    }

    var miniCardHeight: CGFloat {
        isTabletLayout ? 52 : 26
    }

    var handCardWidth: CGFloat {
        isTabletLayout ? 112 : 60
    }

    var handCardHeight: CGFloat {
        isTabletLayout ? 158 : 85
    }

    var handSectionHeight: CGFloat {
        isTabletLayout ? 250 : 120
    }

    var handRotationPad: CGFloat {
        isTabletLayout ? 240 : 80
    }

    var handPreferredOverlap: CGFloat {
        isTabletLayout ? 52 : 30
    }

    var handAnglePerCard: Double {
        isTabletLayout ? 2.6 : 3.5
    }

    var handOuterDip: CGFloat {
        isTabletLayout ? 22 : 12
    }

    @ViewBuilder
    func seatChip(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let chip = seatChipContent(seat, table)
        if settings.showFullTrickHistory {
            Button {
                toggleTrickHistorySeat(seat)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(seatName(seat)) trick history")
        } else {
            chip
        }
    }

    func seatChipContent(_ seat: PlayerID, _ table: PlayerView) -> some View {
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let selected = settings.showFullTrickHistory && selectedTrickHistorySeat == seat
        let tint = TableStyle.teamTint(Seats.team(of: seat))
        return VStack(spacing: isTabletLayout ? 4 : 2) {
            HStack(spacing: isTabletLayout ? 6 : 4) {
                if dealerSeat(table) == seat {
                    Text("D")
                        .font(TableTypography.display(isTabletLayout ? .callout : .caption2, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: isTabletLayout ? 24 : 16,
                               height: isTabletLayout ? 24 : 16)
                        .background(Circle().fill(.white.opacity(0.9)))
                }
                Text(seatName(seat))
                    .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .bold))
                    .foregroundStyle(.white).lineLimit(1)
            }
            seatSubtitle(seat, table)
        }
        .padding(.horizontal, isTabletLayout ? 20 : 12)
        .padding(.vertical, isTabletLayout ? 10 : 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(tint.opacity(toAct ? 0.20 : 0.11))
                }
        }
        .overlay(Capsule().stroke(selected ? TableStyle.tableGold : (toAct ? TableStyle.panelStrokeActive : tint.opacity(0.55)),
                                  lineWidth: selected ? (isTabletLayout ? 3 : 2.5) : (toAct ? (isTabletLayout ? 3 : 2.5) : 1.5)))
        .shadow(color: selected ? TableStyle.tableGold.opacity(0.45) : (toAct ? TableStyle.panelStrokeActive.opacity(0.48) : .black.opacity(0.25)),
                radius: selected || toAct ? (isTabletLayout ? 12 : 8) : 3, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: selected)
    }

    @ViewBuilder
    func trickHistoryOverlay(_ table: PlayerView) -> some View {
        if settings.showFullTrickHistory, let seat = selectedTrickHistorySeat {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { dismissTrickHistory() }
                .transition(.opacity)

            TrickHistoryPanel(
                seat: seat,
                completedTricks: table.completedTricks,
                seatName: seatName,
                seatShort: seatShort,
                miniCardWidth: isTabletLayout ? 66 : 46,
                miniCardHeight: isTabletLayout ? 46 : 32,
                maxHeight: isTabletLayout ? 360 : 250,
                onClose: dismissTrickHistory)
            .padding(.horizontal, isTabletLayout ? 24 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, isTabletLayout ? 292 : 142)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    func toggleTrickHistorySeat(_ seat: PlayerID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedTrickHistorySeat = selectedTrickHistorySeat == seat ? nil : seat
        }
    }

    func dismissTrickHistory() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedTrickHistorySeat = nil
        }
    }

    @ViewBuilder
    func seatSubtitle(_ seat: PlayerID, _ table: PlayerView) -> some View {
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidHistoryLabel(last.action))
                    .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white)
            } else {
                Text("…")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: isTabletLayout ? 5 : 3) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill")
                        .font(.system(size: isTabletLayout ? 12 : 8))
                        .foregroundStyle(TableStyle.tableGold)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Footer (widow + last trick)

    @ViewBuilder
    func footerStrip(_ table: PlayerView) -> some View {
        let widow = settings.showWidow ? (table.widow ?? []) : []
        let showLast = settings.showLastTrick && table.lastTrick != nil
        // The discard announcement is public table talk even when the widow
        // panel is hidden (privately-held widow, or the display toggle off) —
        // it gets its own small panel in that case.
        let loneAnnouncement: DiscardAnnouncement? = {
            guard widow.isEmpty, let ann = table.discardAnnouncement,
                  ann.hasPublicContent else { return nil }
            return ann
        }()
        if !widow.isEmpty || showLast || loneAnnouncement != nil {
            HStack(alignment: .bottom, spacing: isTabletLayout ? 22 : 12) {
                if let ann = loneAnnouncement {
                    HStack(spacing: isTabletLayout ? 6 : 4) {
                        Text(ann.summaryText)
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                            MiniCardFace(card: entry.card,
                                         width: miniCardWidth * 0.8,
                                         height: miniCardHeight * 0.8)
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
                if !widow.isEmpty {
                    VStack(alignment: .leading, spacing: isTabletLayout ? 7 : 4) {
                        Text("Widow")
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: isTabletLayout ? 8 : 5) {
                            ForEach(keyedHand(widow), id: \.key) { entry in
                                MiniCardFace(card: entry.card,
                                             width: miniCardWidth,
                                             height: miniCardHeight)
                            }
                        }
                        // Public discard announcement: trump count spoken,
                        // money shown face-up. Stays visible all hand, like
                        // the widow itself.
                        if let ann = table.discardAnnouncement, ann.hasPublicContent {
                            HStack(spacing: isTabletLayout ? 6 : 4) {
                                Text(ann.summaryText)
                                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                                    .foregroundStyle(.white.opacity(0.7))
                                ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                                    MiniCardFace(card: entry.card,
                                                 width: miniCardWidth * 0.8,
                                                 height: miniCardHeight * 0.8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
                Spacer(minLength: isTabletLayout ? 16 : 8)
                if showLast, let last = table.lastTrick {
                    VStack(alignment: .trailing, spacing: isTabletLayout ? 7 : 4) {
                        Text("Last trick · \(seatShort(last.winner)) $\(last.value / 1000)k")
                            .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: isTabletLayout ? 8 : 5) {
                            ForEach(keyedPlays(last.plays), id: \.key) { entry in
                                MiniCardFace(card: entry.play.card,
                                             faded: entry.play.player != last.winner,
                                             width: miniCardWidth,
                                             height: miniCardHeight)
                            }
                        }
                    }
                    .padding(.horizontal, isTabletLayout ? 12 : 8)
                    .padding(.vertical, isTabletLayout ? 10 : 7)
                    .tablePanel(cornerRadius: isTabletLayout ? 14 : 10, shadowOpacity: 0.16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isTabletLayout ? 8 : 4)
        }
    }

    func hintText(_ s: String) -> some View {
        Text(s)
            .font(TableTypography.display(isTabletLayout ? .callout : .caption))
            .italic()
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Hand

    func handSection(table: PlayerView, decision: PlayerView, interactive: Bool) -> some View {
        VStack(spacing: isTabletLayout ? 4 : 2) {
            Text("Your hand (\(table.myHand.count))")
                .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                .foregroundStyle(.white.opacity(0.6))
            FannedHand(cards: table.myHand,
                       cardWidth: handCardWidth,
                       rotationPad: handRotationPad,
                       preferredOverlap: handPreferredOverlap,
                       anglePerCard: handAnglePerCard,
                       outerDip: handOuterDip,
                       liftedCards: discardSelection) { card, n in
                handCard(card, decision: decision, interactive: interactive, totalCards: n)
            }
            .padding(.top, isTabletLayout ? 34 : 18)
            .padding(.bottom, isTabletLayout ? 48 : 30)
            .frame(height: handSectionHeight)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Board helpers

    func isActionPhase(_ p: Phase) -> Bool {
        switch p {
        case .bidding, .namingTrump, .widowDiscard: return true
        default: return false
        }
    }

    func startDealAnimationIfNeeded(_ token: Int) {
        guard token >= 0, token != lastDealAnimationToken else { return }
        lastDealAnimationToken = token
        showingDealAnimation = true
        dealAnimationTrigger = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            dealAnimationTrigger = token
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            if lastDealAnimationToken == token {
                showingDealAnimation = false
            }
        }
    }

    func isLivePhase(_ p: Phase) -> Bool {
        switch p {
        case .bidding, .namingTrump, .widowDiscard, .trickPlay: return true
        default: return false
        }
    }

    /// The dealer sits one seat right of the opener (opener leads the bidding).
    func dealerSeat(_ table: PlayerView) -> PlayerID {
        PlayerID((table.opener.raw + Seats.count - 1) % Seats.count)
    }

    /// The seat `dir` clockwise steps from `viewer` (1 left, 2 across, 3 right).
    func relativeSeat(_ dir: Int, from viewer: PlayerID) -> PlayerID {
        PlayerID((viewer.raw + dir) % Seats.count)
    }

    var feltBackground: some View {
        TableFeltBackground()
    }

}
