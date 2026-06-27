//
//  GameView+Panels.swift
//  Make-a-Million
//
//  Misdeal/bid-history overlays, bidding/trump/discard panels, and formatting helpers.
//  Split out of GameView.swift; same type via `extension GameBody`.
//

import SwiftUI

extension GameBody {

    /// Misdeal notice. Automatic rule: a brief "redealing" banner. Agreement
    /// rule: when it is this player's turn to vote, the banner carries the
    /// Redeal / Keep buttons; otherwise it shows who the table is waiting on.
    func misdealBanner(_ view: PlayerView, decision: PlayerView,
                               interactive: Bool) -> some View {
        let myMoney = view.myHand.reduce(0) { $0 + $1.moneyValue }
        let canVote = interactive
            && decision.phase == .misdealDecision
            && decision.legalMoves.contains(.declineMisdeal)
        return VStack(spacing: 10) {
            HStack(alignment: .top, spacing: isTabletLayout ? 14 : 10) {
                ZStack {
                    Circle()
                        .fill(TableStyle.teamAmber.opacity(0.24))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .headline, weight: .bold))
                        .foregroundStyle(TableStyle.teamAmber)
                }
                .frame(width: isTabletLayout ? 42 : 34,
                       height: isTabletLayout ? 42 : 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(canVote ? "Misdeal called — redeal?" : "Misdeal called")
                        .font(TableTypography.display(isTabletLayout ? .headline : .subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("A player has too little money in hand. Your hand: $\(myMoney / 1000)k in money cards.")
                        .font(TableTypography.display(isTabletLayout ? .callout : .caption))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
                if !canVote {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TableStyle.teamAmber)
                        .padding(.top, 6)
                }
            }
            if canVote {
                HStack(spacing: 10) {
                    Button("Redeal") {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(.callMisdeal)
                    }
                    .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                      compact: true))
                    Button("Keep this hand") {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(.declineMisdeal)
                    }
                    .buttonStyle(TablePillButtonStyle(tint: TableStyle.teamAmber,
                                                      emphasis: .tinted,
                                                      compact: true))
                }
                .font(TableTypography.display(.subheadline, weight: .semibold))
            }
        }
        .padding(.horizontal, isTabletLayout ? 18 : 14)
        .padding(.vertical, isTabletLayout ? 14 : 12)
        .frame(maxWidth: isTabletLayout ? 620 : .infinity)
        .background {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                        .fill(.black.opacity(0.24))
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(TableStyle.teamAmber)
                        .frame(width: isTabletLayout ? 7 : 5)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .stroke(TableStyle.teamAmber.opacity(0.82), lineWidth: 1.5)
        }
        .shadow(color: TableStyle.teamAmber.opacity(0.20), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }

    // MARK: Bid history strip (during bidding, and through the hand when
    // the Card display setting keeps it visible)

    func showsBidHistoryStrip(_ table: PlayerView) -> Bool {
        guard !table.bidHistory.isEmpty else { return false }
        return table.phase == .bidding || settings.showBidHistoryDuringHand
    }

    func bidHistoryStrip(_ table: PlayerView) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isTabletLayout ? 8 : 5) {
                Text("Bids")
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(Array(table.bidHistory.enumerated()), id: \.offset) { _, record in
                    HStack(spacing: 4) {
                        Text(seatShort(record.player))
                            .font(TableTypography.display(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(bidHistoryLabel(record.action))
                            .font(TableTypography.money(isTabletLayout ? .callout : .caption2))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, isTabletLayout ? 9 : 6)
                    .padding(.vertical, isTabletLayout ? 5 : 3)
                    .background(Capsule().fill(bidHistoryTint(record).opacity(0.16)))
                    .overlay(Capsule().stroke(bidHistoryTint(record).opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(.center)
    }

    // MARK: Action panel (bid / name trump / discard)

    /// Floats over the empty center during trump naming / widow discard.
    /// Bidding uses `biddingActionPanel` instead so the bid context remains
    /// visible around the table.
    @ViewBuilder
    func actionPanel(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch view.phase {
            case .widowDiscard: widowDiscardPanel(view)
            case .namingTrump:  trumpNamingPanel(view)
            default:            EmptyView()
            }
        }
        .frame(width: actionPanelContentWidth(for: view), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(14)
        .tablePanel(cornerRadius: 18, shadowOpacity: 0.34)
    }

    func actionPanelContentWidth(for view: PlayerView) -> CGFloat? {
        switch view.phase {
        case .namingTrump:
            return trumpPanelContentWidth
        case .widowDiscard:
            return discardPanelContentWidth
        default:
            return nil
        }
    }

    func biddingActionPanel(_ view: PlayerView) -> some View {
        biddingPanel(view)
            .padding(.vertical, isTabletLayout ? 6 : 5)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.26)
    }

    @ViewBuilder
    func biddingPanel(_ view: PlayerView) -> some View {
        let passMove = view.legalMoves.first { $0.isPass }
        let bidMoves = view.legalMoves.filter { $0.bidAmount != nil }
        let bidAmounts = bidMoves.compactMap(\.bidAmount)
        let safeBidIndex = min(selectedBidIndex, max(0, bidMoves.count - 1))
        let bidSelection = Binding<Int>(
            get: { min(selectedBidIndex, max(0, bidMoves.count - 1)) },
            set: { selectedBidIndex = $0 }
        )

        HStack(spacing: isTabletLayout ? 12 : 8) {
            if !bidMoves.isEmpty {
                BidAmountWheel(
                    amounts: bidAmounts,
                    selection: bidSelection,
                    width: isTabletLayout ? 112 : 82,
                    height: isTabletLayout ? 76 : 62,
                    rowHeight: isTabletLayout ? 24 : 20,
                    textStyle: isTabletLayout ? .title3 : .callout)
            }

            HStack(spacing: isTabletLayout ? 10 : 8) {
                Button {
                    guard !bidMoves.isEmpty else { return }
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    submit(bidMoves[safeBidIndex])
                } label: {
                    Text("Bid")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: isTabletLayout ? 112 : 78,
                               height: isTabletLayout ? 44 : 36)
                        .background(Capsule(style: .continuous).fill(TableStyle.actionBlue))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(bidMoves.isEmpty)
                .opacity(bidMoves.isEmpty ? 0.45 : 1)

                Button {
                    guard let passMove else { return }
                    SoundEffectPlayer.shared.play(.buttonSelect)
                    submit(passMove)
                } label: {
                    Text("Pass")
                        .font(TableTypography.display(isTabletLayout ? .title3 : .subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: isTabletLayout ? 112 : 78,
                               height: isTabletLayout ? 44 : 36)
                        .background(Capsule(style: .continuous).fill(TableStyle.passGray.opacity(0.82)))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(passMove == nil)
                .opacity(passMove == nil ? 0.45 : 1)
            }
        }
        .padding(.horizontal, isTabletLayout ? 12 : 10)
    }

    func trumpNamingPanel(_ view: PlayerView) -> some View {
        // Build the four color buttons from CardColor directly, not from
        // move.label — the bid panel's label-munging produced "Bid Trump: Red",
        // which is what this panel is here to replace.
        let trumpMoves: [(CardColor, Move)] = view.legalMoves.compactMap { move in
            if case .nameTrump(let c) = move { return (c, move) }
            return nil
        }
        let buttonWidth = trumpButtonWidth
        let buttonHeight: CGFloat = isTabletLayout ? 52 : 48
        let gridSpacing = trumpGridSpacing
        let contentWidth = trumpPanelContentWidth
        let columns = [
            GridItem(.fixed(buttonWidth), spacing: gridSpacing),
            GridItem(.fixed(buttonWidth), spacing: gridSpacing)
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Choose trump. Discard comes next.")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: contentWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(trumpMoves, id: \.0) { color, move in
                    // `CardColor.black` maps to `Color.primary` in `swatch`, which
                    // inverts in dark mode and would render the Black trump button
                    // as white-on-white. The selector should always show the suit
                    // color faithfully, so override `.black` to a literal black.
                    let solidSwatch = TableStyle.suitSwatch(color)
                    Button {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(move)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(solidSwatch)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                            Text(color.displayName)
                                .font(TableTypography.display(.headline, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .frame(width: buttonWidth, height: buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(solidSwatch.opacity(color == .black ? 0.68 : 0.76))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(solidSwatch, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: contentWidth)
        }
    }

    func widowDiscardPanel(_ view: PlayerView) -> some View {
        let count = discardSelection.count
        let ready = count == 3
        let legalMove = ready ? matchingWidowDiscardMove(selection: discardSelection, in: view) : nil
        let panelWidth = discardPanelContentWidth

        return VStack(alignment: .leading, spacing: 8) {
            Text(discardHelpText(for: view))
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: panelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if ready && legalMove == nil {
                Text("That discard isn't legal — discard your other colors first, then trump, and money only when nothing else is left.")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(TableStyle.teamAmber)
                    .frame(width: panelWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("\(count) of 3 selected")
                    .font(TableTypography.money(.callout, weight: .regular))
                    .foregroundStyle(.white)
                Spacer()
                Button("Discard selected") {
                    if let move = legalMove {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        submit(move)
                        discardSelection = []
                    }
                }
                .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                  compact: true))
                .disabled(legalMove == nil)
                .opacity(legalMove == nil ? 0.50 : 1.0)
            }
            .frame(width: panelWidth)
        }
        .frame(width: panelWidth, alignment: .leading)
    }

    var trumpButtonWidth: CGFloat {
        isTabletLayout ? 142 : 126
    }

    var trumpGridSpacing: CGFloat {
        10
    }

    var trumpPanelContentWidth: CGFloat {
        trumpButtonWidth * 2 + trumpGridSpacing
    }

    var discardPanelContentWidth: CGFloat {
        isTabletLayout ? 330 : 286
    }
    
    func discardHelpText(for view: PlayerView) -> String {
        if let trump = view.trump {
            return "Select 3 cards. Other colors go first; \(trump.displayName) trump and money unlock only when required."
        } else {
            return "Select 3 cards from your hand."
        }
    }

    func matchingWidowDiscardMove(selection: Set<Card>, in view: PlayerView) -> Move? {
        view.legalMoves.first { move in
            guard case .discardWidow(let cards) = move else { return false }
            return Set(cards) == selection
        }
    }

    func isDiscardSelectable(_ card: Card, in view: PlayerView) -> Bool {
        guard view.phase == .widowDiscard else { return false }
        if card.isSpecial { return false }
        // Mirror of GameState.isLegalWidowDiscard's tier order: plain cards
        // fill the discard first, then trump (announced by count), then
        // money (shown face-up). A protected card is only tappable when the
        // safer tiers combined can't fill the three slots. The engine's
        // legality check is the authority; this mirror keeps the UI from
        // offering taps the engine would reject.
        let plainPool = view.myHand.filter { candidate in
            guard !candidate.isSpecial, !candidate.isMoney else { return false }
            if let trump = view.trump {
                return candidate.effectiveColor(trump: trump) != trump
            }
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

    func toggleDiscardSelection(_ card: Card) {
        if discardSelection.contains(card) {
            discardSelection.remove(card)
        } else if discardSelection.count < 3 {
            discardSelection.insert(card)
        }
    }

    // MARK: Hand complete

    func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        let action = dealAnother.map { deal in
            HandCompleteAction(
                title: s.matchWinner == nil ? "Next hand" : "Start new match",
                systemImage: s.matchWinner == nil
                    ? "arrow.right.circle.fill"
                    : "arrow.clockwise.circle.fill",
                action: deal)
        }
        return HandCompleteScorecard(
            snapshot: s,
            teamName: { teamName($0) },
            seatName: { seatName($0) },
            seatShort: { seatShort($0) },
            action: action)
    }

    func teamName(_ team: Int) -> String {
        team == 0 ? teamAName : teamBName
    }

    // MARK: Helpers - Dynamic Seat Naming

    func seatName(_ p: PlayerID) -> String {
        guard p.raw < seatNames.count else { return "Seat \(p.raw)" }
        return seatNames[p.raw]
    }
    
    func seatShort(_ p: PlayerID) -> String {
        guard p.raw < seatNames.count else { return "S\(p.raw)" }
        let name = seatNames[p.raw]
        // If it's the local player, keep it clean
        if name == "You" || name.contains("(You)") { return "You" }
        return String(name.prefix(3)).uppercased()
    }

    func isPlayable(_ card: Card, in view: PlayerView) -> Bool {
        view.legalMoves.contains {
            if case .play(let c) = $0 { return c == card }; return false
        }
    }

    func bidHistoryLabel(_ action: BidAction) -> String {
        switch action {
        case .pass: return "Pass"
        case .bid(let amount): return "$\(amount / 1000)k"
        }
    }

    func bidHistoryTint(_ record: BidRecord) -> Color {
        switch record.action {
        case .pass: return TableStyle.passGray
        case .bid: return TableStyle.tableGold
        }
    }

    static func animationToken(_ v: PlayerView) -> Int {
        var token = v.myHand.count &* 1000
        token &+= (v.currentTrick?.plays.count ?? 0) &* 13
        token &+= v.completedTricks.count &* 100
        token &+= v.bidHistory.count &* 7
        return token
    }

    func cardChip(_ card: Card, faded: Bool, selected: Bool = false, highlighted: Bool = false, totalCards: Int = 1) -> some View {
        CardFace(card: card, faded: faded, selected: selected,
                 highlighted: highlighted,
                 width: handCardWidth,
                 height: handCardHeight,
                 dense: totalCards > 12)
    }
}
