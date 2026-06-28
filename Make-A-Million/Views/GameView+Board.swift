//
//  GameView+Board.swift
//  Make-a-Million
//
//  Board, header badges, seat chips, layout metrics, footer, and hand.
//  Split out of GameView.swift; same type via `extension GameBody`.
//

import SwiftUI

extension GameBody {

    func defaultLayout() -> GameBodyLayout {
        GameBodyLayout.resolve(
            size: .zero,
            horizontalSizeClass: horizontalSizeClass,
            allowsPhoneLandscape: false)
    }

    func resolvedLayout(_ layout: GameBodyLayout?) -> GameBodyLayout {
        layout ?? defaultLayout()
    }

    @ViewBuilder
    func handCard(
        _ card: Card,
        decision: PlayerView,
        interactive: Bool,
        totalCards: Int,
        layout: GameBodyLayout? = nil
    ) -> some View {
        let resolved = resolvedLayout(layout)
        let playable = isPlayable(card, in: decision)
        let discardSelectable = isDiscardSelectable(card, in: decision)
        let selected = discardSelection.contains(card)

        Group {
            if interactive && decision.phase == .trickPlay && playable {
                Button { submit(.play(card)) } label: {
                    cardChip(card, faded: false, selected: false, highlighted: true, totalCards: totalCards, layout: resolved)
                }
                .buttonStyle(.plain)
            } else if interactive && decision.phase == .widowDiscard && discardSelectable {
                Button {
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    toggleDiscardSelection(card)
                } label: {
                    cardChip(card, faded: false, selected: selected, highlighted: true, totalCards: totalCards, layout: resolved)
                }
                .buttonStyle(.plain)
            } else {
                // No fade for non-discardable cards — the green border on
                // legal ones is enough to convey legality, same affordance
                // as during trick play.
                cardChip(card, faded: false, selected: selected, totalCards: totalCards, layout: resolved)
            }
        }
        .matchedGeometryEffect(id: cardKey(card), in: cardNS)
    }

    // MARK: Score bar

    // MARK: Board header (scores + phase + trump / high bid)

    func boardHeader(
        _ table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        layout: GameBodyLayout? = nil
    ) -> some View {
        let resolved = resolvedLayout(layout)
        let status = phaseStatus(table: table,
                                 decision: decision,
                                 interactive: interactive)
        let scoreMinHeight = resolved.isPhoneLandscape
            ? nil
            : (boardHeaderCenterHeight > 0 ? boardHeaderCenterHeight : nil)
        return HStack(alignment: .top, spacing: resolved.isTablet ? 14 : (resolved.isPhoneLandscape ? 4 : 6)) {
            teamScorePill(team: 0, table, minHeight: scoreMinHeight, layout: resolved)
            VStack(spacing: resolved.isPhoneLandscape ? 3 : 6) {
                Text(table.phase.headline)
                    .font(TableTypography.display(resolved.isTablet ? .title2 : (resolved.isPhoneLandscape ? .subheadline : .headline), weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                headerBadges(table, layout: resolved)
                if let status {
                    phaseStatusBadge(status, layout: resolved)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BoardHeaderCenterHeightKey.self,
                                           value: proxy.size.height)
                }
            }
            teamScorePill(team: 1, table, minHeight: scoreMinHeight, layout: resolved)
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
        _ status: (title: String, detail: String?, icon: String, tint: Color),
        layout: GameBodyLayout? = nil
    ) -> some View {
        let resolved = resolvedLayout(layout)
        if resolved.isTablet {
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
            HStack(alignment: .center, spacing: resolved.isPhoneLandscape ? 5 : 7) {
                Image(systemName: status.icon)
                    .font(TableTypography.display(.caption, weight: .bold))
                    .frame(width: resolved.isPhoneLandscape ? 14 : 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.title)
                        .font(TableTypography.display(resolved.isPhoneLandscape ? .caption2 : .caption, weight: .bold))
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
            .padding(.horizontal, resolved.isPhoneLandscape ? 7 : 10)
            .padding(.vertical, resolved.isPhoneLandscape ? 4 : 6)
            .background(Capsule().fill(status.tint.opacity(0.20)))
            .overlay(Capsule().stroke(status.tint.opacity(0.58), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    func headerBadges(_ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        if table.trump == nil, let bid = table.highBid, let bidder = table.highBidder {
            HStack {
                Spacer(minLength: 0)
                bidBadge(bidder: bidder, amount: bid, layout: resolved)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: resolved.isTablet ? 10 : (resolved.isPhoneLandscape ? 4 : 6)) {
                if let t = table.trump { trumpBadge(t, layout: resolved) }
                if let bid = table.highBid, let bidder = table.highBidder {
                    bidBadge(bidder: bidder, amount: bid, layout: resolved)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    func teamScorePill(team: Int,
                               _ table: PlayerView,
                               minHeight: CGFloat? = nil,
                               layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        let tint = TableStyle.teamTint(team)
        let isMine = Seats.team(of: table.me) == team
        let hand = table.liveHandScore[team, default: 0]
        let match = table.matchScore[team, default: 0]
        // "Show live scores" off: hide the running hand total (captured
        // tricks stay face-down at a real table); the settled match score
        // still shows.
        return VStack(alignment: .leading, spacing: resolved.isTablet ? 4 : 2) {
            Text(team == 0 ? teamAName : teamBName)
                .font(TableTypography.display(resolved.isTablet ? .callout : .caption2, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(settings.showLiveScores ? "$\(hand / 1000)k" : "$\(match / 1000)k")
                .font(TableTypography.money(resolved.isTablet ? .title3 : (resolved.isPhoneLandscape ? .caption : .callout)))
                .foregroundStyle(.white)
            if settings.showLiveScores {
                Text("$\(match / 1000)k")
                    .font(TableTypography.money(resolved.isTablet ? .callout : .caption2, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, resolved.isTablet ? 16 : (resolved.isPhoneLandscape ? 7 : 9))
        .padding(.vertical, resolved.isTablet ? 12 : (resolved.isPhoneLandscape ? 5 : 7))
        .frame(width: resolved.isTablet ? 142 : (resolved.isPhoneLandscape ? 76 : 88), alignment: .leading)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: resolved.isTablet ? 16 : 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: resolved.isTablet ? 16 : 12, style: .continuous)
                        .fill(tint.opacity(isMine ? 0.18 : 0.10))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: resolved.isTablet ? 16 : 12, style: .continuous)
            .stroke(tint.opacity(isMine ? 0.82 : 0.42), lineWidth: isMine ? 2 : 1))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    func trumpBadge(_ color: CardColor, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        let swatch = TableStyle.suitSwatch(color)
        return HStack(spacing: resolved.isTablet ? 8 : (resolved.isPhoneLandscape ? 4 : 5)) {
            Circle().fill(swatch)
                .frame(width: resolved.isTablet ? 18 : (resolved.isPhoneLandscape ? 9 : 12),
                       height: resolved.isTablet ? 18 : (resolved.isPhoneLandscape ? 9 : 12))
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            Text(color.displayName)
                .font(TableTypography.display(resolved.isTablet ? .headline : (resolved.isPhoneLandscape ? .caption2 : .caption), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, resolved.isTablet ? 14 : (resolved.isPhoneLandscape ? 7 : 9))
        .padding(.vertical, resolved.isTablet ? 7 : (resolved.isPhoneLandscape ? 3 : 4))
        .background(Capsule().fill(swatch.opacity(color == .black ? 0.34 : 0.22)))
        .overlay(Capsule().stroke(swatch.opacity(0.68), lineWidth: 1))
        .accessibilityLabel("Trump: \(color.displayName)")
    }

    func bidBadge(bidder: PlayerID, amount: Int, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        return HStack(spacing: resolved.isTablet ? 7 : 4) {
            Image(systemName: "crown.fill")
                .font(resolved.isTablet ? .subheadline : .caption2)
                .foregroundStyle(TableStyle.tableGold)
            Text("\(seatShort(bidder)) $\(amount / 1000)k")
                .font(TableTypography.display(resolved.isTablet ? .headline : (resolved.isPhoneLandscape ? .caption2 : .caption), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, resolved.isTablet ? 14 : (resolved.isPhoneLandscape ? 7 : 9))
        .padding(.vertical, resolved.isTablet ? 7 : (resolved.isPhoneLandscape ? 3 : 4))
        .background(Capsule().fill(TableStyle.tableGold.opacity(0.18)))
        .overlay(Capsule().stroke(TableStyle.tableGold.opacity(0.58), lineWidth: 1))
    }

    // MARK: Board (opponent seats + center trick)

    func boardArea(_ table: PlayerView,
                           showLiveCards: Bool = true,
                           showsIdleText: Bool = true,
                           dealAnimationTrigger: Int? = nil,
                           layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        let metrics = soloBoardMetrics(layout: resolved)
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
                        cardWidth: resolved.isTablet ? 104 : (resolved.isPhoneLandscape ? 62 : 74),
                        cardHeight: resolved.isTablet ? 146 : (resolved.isPhoneLandscape ? 88 : 104),
                        spreadScale: resolved.isTablet ? 0.66 : (resolved.isPhoneLandscape ? 0.54 : 0.60))
                    .frame(width: metrics.frame, height: metrics.frame)
                }
            }

            // All four seats are marked, relative to the local player: bottom
            // (you), left, top (partner), right — mirroring the tabletop board.
            seatChip(relativeSeat(2, from: table.me), table, layout: resolved)
                .offset(seatChipOffset(direction: 2, layout: resolved))
            seatChip(table.me, table, layout: resolved)
                .offset(seatChipOffset(direction: 0, layout: resolved))
            seatChip(relativeSeat(1, from: table.me), table, layout: resolved)
                .offset(seatChipOffset(direction: 1, layout: resolved))
            seatChip(relativeSeat(3, from: table.me), table, layout: resolved)
                .offset(seatChipOffset(direction: 3, layout: resolved))
        }
        .frame(maxWidth: .infinity)
        .frame(height: soloBoardHeight(layout: resolved))
    }

    func seatChipOffset(direction: Int, layout: GameBodyLayout? = nil) -> CGSize {
        let resolved = resolvedLayout(layout)
        let distance = soloBoardSeatDistance(layout: resolved)
        switch direction {
        case 0: return CGSize(width: 0, height: distance)
        case 1: return CGSize(width: -distance, height: 0)
        case 2: return CGSize(width: 0, height: -distance)
        case 3: return CGSize(width: distance, height: 0)
        default: return .zero
        }
    }

    var isTabletLayout: Bool {
        defaultLayout().isTablet
    }

    var soloBoardMetrics: CenterTrickView.Metrics {
        soloBoardMetrics(layout: defaultLayout())
    }

    var soloBoardHeight: CGFloat {
        soloBoardHeight(layout: defaultLayout())
    }

    var soloBoardSeatDistance: CGFloat {
        soloBoardSeatDistance(layout: defaultLayout())
    }

    var miniCardWidth: CGFloat {
        miniCardWidth(layout: defaultLayout())
    }

    var miniCardHeight: CGFloat {
        miniCardHeight(layout: defaultLayout())
    }

    var handCardWidth: CGFloat {
        handCardWidth(layout: defaultLayout())
    }

    var handCardHeight: CGFloat {
        handCardHeight(layout: defaultLayout())
    }

    var handSectionHeight: CGFloat {
        handSectionHeight(layout: defaultLayout())
    }

    var handRotationPad: CGFloat {
        handRotationPad(layout: defaultLayout())
    }

    var handPreferredOverlap: CGFloat {
        handPreferredOverlap(layout: defaultLayout())
    }

    var handAnglePerCard: Double {
        handAnglePerCard(layout: defaultLayout())
    }

    var handOuterDip: CGFloat {
        handOuterDip(layout: defaultLayout())
    }

    func soloBoardMetrics(layout: GameBodyLayout) -> CenterTrickView.Metrics {
        switch layout.mode {
        case .tablet:
            return .tablet
        case .phoneLandscape:
            return CenterTrickView.Metrics(
                cardW: 56,
                cardH: 80,
                spread: 62,
                circle: 176,
                frame: 218,
                ledDot: 12,
                idleFont: TableTypography.display(.caption, weight: .bold))
        case .phonePortrait:
            return .phone
        }
    }

    func soloBoardHeight(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 660
        case .phoneLandscape: return min(260, max(230, layout.viewport.height - 118))
        case .phonePortrait: return min(334, max(304, layout.contentHeight * 0.42))
        }
    }

    func soloBoardSeatDistance(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 304
        case .phoneLandscape: return 122
        case .phonePortrait: return layout.viewport.height < 720 ? 148 : 158
        }
    }

    func miniCardWidth(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 84
        case .phoneLandscape: return 36
        case .phonePortrait: return 42
        }
    }

    func miniCardHeight(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 58
        case .phoneLandscape: return 25
        case .phonePortrait: return 29
        }
    }

    func handCardWidth(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 124
        case .phoneLandscape:
            let widthLimited = layout.landscapeInfoColumnWidth / (layout.viewport.width < 700 ? 7.2 : 6.85)
            let heightLimited = layout.contentHeight * (layout.viewport.height < 390 ? 0.20 : 0.21)
            let target = min(widthLimited, heightLimited, layout.viewport.width < 700 ? 62 : 78)
            let minimum: CGFloat = layout.viewport.width < 620 ? 46 : (layout.viewport.width < 700 ? 52 : 68)
            return max(minimum, target)
        case .phonePortrait: return 66
        }
    }

    func handCardHeight(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 176
        case .phoneLandscape: return handCardWidth(layout: layout) * 1.42
        case .phonePortrait: return 94
        }
    }

    func handSectionHeight(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 276
        case .phoneLandscape: return handCardHeight(layout: layout) + (layout.viewport.width < 700 ? 28 : 36)
        case .phonePortrait: return 136
        }
    }

    func handRotationPad(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 252
        case .phoneLandscape: return max(44, handCardWidth(layout: layout) * 0.74)
        case .phonePortrait: return 86
        }
    }

    func handPreferredOverlap(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 58
        case .phoneLandscape: return handCardWidth(layout: layout) * 0.56
        case .phonePortrait: return 32
        }
    }

    func handAnglePerCard(layout: GameBodyLayout) -> Double {
        switch layout.mode {
        case .tablet: return 2.6
        case .phoneLandscape: return 2.2
        case .phonePortrait: return 3.5
        }
    }

    func handOuterDip(layout: GameBodyLayout) -> CGFloat {
        switch layout.mode {
        case .tablet: return 24
        case .phoneLandscape: return layout.viewport.width < 700 ? 7 : 10
        case .phonePortrait: return 13
        }
    }

    @ViewBuilder
    func seatChip(_ seat: PlayerID, _ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        let chip = seatChipContent(seat, table, layout: resolved)
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

    func seatChipContent(_ seat: PlayerID, _ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        let toAct = table.toAct == seat && isLivePhase(table.phase)
        let selected = settings.showFullTrickHistory && selectedTrickHistorySeat == seat
        let tint = TableStyle.teamTint(Seats.team(of: seat))
        return VStack(spacing: resolved.isTablet ? 4 : 2) {
            HStack(spacing: resolved.isTablet ? 6 : 4) {
                if dealerSeat(table) == seat {
                    Text("D")
                        .font(TableTypography.display(resolved.isTablet ? .callout : .caption2, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: resolved.isTablet ? 24 : (resolved.isPhoneLandscape ? 13 : 16),
                               height: resolved.isTablet ? 24 : (resolved.isPhoneLandscape ? 13 : 16))
                        .background(Circle().fill(.white.opacity(0.9)))
                }
                Text(seatName(seat))
                    .font(TableTypography.display(resolved.isTablet ? .title3 : (resolved.isPhoneLandscape ? .caption : .subheadline), weight: .bold))
                    .foregroundStyle(.white).lineLimit(1)
            }
            seatSubtitle(seat, table, layout: resolved)
        }
        .padding(.horizontal, resolved.isTablet ? 20 : (resolved.isPhoneLandscape ? 9 : 12))
        .padding(.vertical, resolved.isTablet ? 10 : (resolved.isPhoneLandscape ? 4 : 6))
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(tint.opacity(toAct ? 0.20 : 0.11))
                }
        }
        .overlay(Capsule().stroke(selected ? TableStyle.tableGold : (toAct ? TableStyle.panelStrokeActive : tint.opacity(0.55)),
                                  lineWidth: selected ? (resolved.isTablet ? 3 : 2.5) : (toAct ? (resolved.isTablet ? 3 : 2.5) : 1.5)))
        .shadow(color: selected ? TableStyle.tableGold.opacity(0.45) : (toAct ? TableStyle.panelStrokeActive.opacity(0.48) : .black.opacity(0.25)),
                radius: selected || toAct ? (resolved.isTablet ? 12 : 8) : 3, y: 2)
        .scaleEffect(toAct ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toAct)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: selected)
    }

    @ViewBuilder
    func trickHistoryOverlay(_ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
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
                miniCardWidth: resolved.isTablet ? 76 : (resolved.isPhoneLandscape ? 46 : 52),
                miniCardHeight: resolved.isTablet ? 53 : (resolved.isPhoneLandscape ? 32 : 36),
                maxHeight: resolved.isTablet ? 390 : (resolved.isPhoneLandscape ? 220 : 280),
                onClose: dismissTrickHistory)
            .padding(.horizontal, resolved.isTablet ? 24 : 14)
            .frame(maxWidth: resolved.isPhoneLandscape ? 390 : .infinity,
                   maxHeight: .infinity,
                   alignment: resolved.isPhoneLandscape ? .bottomTrailing : .bottom)
            .padding(.bottom, resolved.isTablet ? 312 : (resolved.isPhoneLandscape ? handSectionHeight(layout: resolved) + 8 : handSectionHeight(layout: resolved) + 24))
            .padding(.trailing, resolved.isPhoneLandscape ? 8 : 0)
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
    func seatSubtitle(_ seat: PlayerID, _ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        if table.phase == .bidding {
            if table.passed.contains(seat) {
                Text("Passed")
                    .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.55))
            } else if let last = table.bidHistory.last(where: { $0.player == seat }) {
                Text(bidHistoryLabel(last.action))
                    .font(TableTypography.money(resolved.isTablet ? .callout : .caption2))
                    .foregroundStyle(.white)
            } else {
                Text("…")
                    .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.4))
            }
        } else {
            let tricks = table.completedTricks.filter { $0.winner == seat }.count
            HStack(spacing: resolved.isTablet ? 5 : 3) {
                if table.highBidder == seat {
                    Image(systemName: "crown.fill")
                        .font(.system(size: resolved.isTablet ? 12 : 8))
                        .foregroundStyle(TableStyle.tableGold)
                }
                Text("\(tricks) trick\(tricks == 1 ? "" : "s")")
                    .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: Footer (widow + last trick)

    @ViewBuilder
    func footerStrip(_ table: PlayerView, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
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
            HStack(alignment: .bottom, spacing: resolved.isTablet ? 22 : (resolved.isPhoneLandscape ? 7 : 12)) {
                if let ann = loneAnnouncement {
                    HStack(spacing: resolved.isTablet ? 6 : 4) {
                        Text(ann.summaryText)
                            .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                            MiniCardFace(card: entry.card,
                                         width: miniCardWidth(layout: resolved) * 0.8,
                                         height: miniCardHeight(layout: resolved) * 0.8)
                        }
                    }
                    .padding(.horizontal, resolved.isTablet ? 12 : (resolved.isPhoneLandscape ? 6 : 8))
                    .padding(.vertical, resolved.isTablet ? 10 : (resolved.isPhoneLandscape ? 5 : 7))
                    .tablePanel(cornerRadius: resolved.isTablet ? 14 : 10, shadowOpacity: 0.16)
                }
                if !widow.isEmpty {
                    VStack(alignment: .leading, spacing: resolved.isTablet ? 7 : (resolved.isPhoneLandscape ? 3 : 4)) {
                        Text("Widow")
                            .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: resolved.isTablet ? 8 : (resolved.isPhoneLandscape ? 4 : 5)) {
                            ForEach(keyedHand(widow), id: \.key) { entry in
                                MiniCardFace(card: entry.card,
                                             width: miniCardWidth(layout: resolved),
                                             height: miniCardHeight(layout: resolved))
                            }
                        }
                        // Public discard announcement: trump count spoken,
                        // money shown face-up. Stays visible all hand, like
                        // the widow itself.
                        if let ann = table.discardAnnouncement, ann.hasPublicContent {
                            HStack(spacing: resolved.isTablet ? 6 : 4) {
                                Text(ann.summaryText)
                                    .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                                    .foregroundStyle(.white.opacity(0.7))
                                ForEach(keyedHand(ann.moneyCards), id: \.key) { entry in
                                    MiniCardFace(card: entry.card,
                                                 width: miniCardWidth(layout: resolved) * 0.8,
                                                 height: miniCardHeight(layout: resolved) * 0.8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, resolved.isTablet ? 12 : (resolved.isPhoneLandscape ? 6 : 8))
                    .padding(.vertical, resolved.isTablet ? 10 : (resolved.isPhoneLandscape ? 5 : 7))
                    .tablePanel(cornerRadius: resolved.isTablet ? 14 : 10, shadowOpacity: 0.16)
                }
                Spacer(minLength: resolved.isTablet ? 16 : (resolved.isPhoneLandscape ? 4 : 8))
                if showLast, let last = table.lastTrick {
                    VStack(alignment: .trailing, spacing: resolved.isTablet ? 7 : (resolved.isPhoneLandscape ? 3 : 4)) {
                        Text("Last trick · \(seatShort(last.winner)) $\(last.value / 1000)k")
                            .font(TableTypography.money(resolved.isTablet ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: resolved.isTablet ? 8 : (resolved.isPhoneLandscape ? 4 : 5)) {
                            ForEach(keyedPlays(last.plays), id: \.key) { entry in
                                MiniCardFace(card: entry.play.card,
                                             faded: entry.play.player != last.winner,
                                             width: miniCardWidth(layout: resolved),
                                             height: miniCardHeight(layout: resolved))
                            }
                        }
                    }
                    .padding(.horizontal, resolved.isTablet ? 12 : (resolved.isPhoneLandscape ? 6 : 8))
                    .padding(.vertical, resolved.isTablet ? 10 : (resolved.isPhoneLandscape ? 5 : 7))
                    .tablePanel(cornerRadius: resolved.isTablet ? 14 : 10, shadowOpacity: 0.16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, resolved.isTablet ? 8 : (resolved.isPhoneLandscape ? 0 : 4))
        }
    }

    func hintText(_ s: String, layout: GameBodyLayout? = nil) -> some View {
        let resolved = resolvedLayout(layout)
        return Text(s)
            .font(TableTypography.display(resolved.isTablet ? .callout : (resolved.isPhoneLandscape ? .caption2 : .caption)))
            .italic()
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Hand

    func handSection(
        table: PlayerView,
        decision: PlayerView,
        interactive: Bool,
        layout: GameBodyLayout? = nil
    ) -> some View {
        let resolved = resolvedLayout(layout)
        return VStack(spacing: resolved.isTablet ? 4 : 2) {
            Text("Your hand (\(table.myHand.count))")
                .font(TableTypography.display(resolved.isTablet ? .callout : .caption2))
                .foregroundStyle(.white.opacity(0.6))
            FannedHand(cards: table.myHand,
                       cardWidth: handCardWidth(layout: resolved),
                       rotationPad: handRotationPad(layout: resolved),
                       preferredOverlap: handPreferredOverlap(layout: resolved),
                       anglePerCard: handAnglePerCard(layout: resolved),
                       outerDip: handOuterDip(layout: resolved),
                       liftedCards: discardSelection) { card, n in
                handCard(card, decision: decision, interactive: interactive, totalCards: n, layout: resolved)
            }
            .padding(.top, resolved.isTablet ? 34 : (resolved.isPhoneLandscape ? 8 : 18))
            .padding(.bottom, resolved.isTablet ? 48 : (resolved.isPhoneLandscape ? 10 : 30))
            .frame(height: handSectionHeight(layout: resolved))
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
