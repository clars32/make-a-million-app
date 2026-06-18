//
//  HandCompleteScorecard.swift
//  Make-a-Million
//
//  Shared end-of-hand recap for solo, host, and tabletop play.
//

import SwiftUI

struct HandCompleteAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct HandCompleteScorecard: View {
    let snapshot: HandCompleteSnapshot
    let teamName: (Int) -> String
    let seatName: (PlayerID) -> String
    let seatShort: (PlayerID) -> String
    var action: HandCompleteAction?
    var showsDebugReveal: Bool = true

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bidHistoryExpanded = false
    @State private var appeared = false

    private var isTabletLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var panelWidth: CGFloat {
        isTabletLayout ? 760 : 430
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                scorecardContent
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(TableMotion.screenTransition(reduceMotion: reduceMotion))
        .onAppear(perform: playEntrance)
    }

    private var scorecardContent: some View {
        VStack(spacing: isTabletLayout ? 18 : 13) {
            heroSection
            scoreboardSection
            if !snapshot.bidHistory.isEmpty {
                bidHistoryPanel
            }
            if showsDebugReveal {
                HandRevealPanel(reveal: snapshot.debugReveal)
            }
            actionButton
        }
        .padding(isTabletLayout ? 24 : 16)
        .frame(maxWidth: panelWidth)
        .tablePanel(cornerRadius: isTabletLayout ? 24 : 18, shadowOpacity: 0.32)
        .padding(.vertical, isTabletLayout ? 18 : 10)
        .padding(.horizontal, isTabletLayout ? 18 : 10)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.965)
        .offset(y: appeared || reduceMotion ? 0 : 24)
    }

    private func playEntrance() {
        guard !appeared else { return }
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
                appeared = true
            }
        }
    }

    private var heroSection: some View {
        let hero = heroCopy
        return HStack(alignment: .center, spacing: isTabletLayout ? 16 : 12) {
            ZStack {
                Circle().fill(hero.tint.opacity(0.22))
                Image(systemName: hero.icon)
                    .font(TableTypography.display(isTabletLayout ? .title : .title2, weight: .bold))
                    .foregroundStyle(hero.tint)
            }
            .frame(width: isTabletLayout ? 62 : 50,
                   height: isTabletLayout ? 62 : 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(hero.eyebrow.uppercased())
                    .font(TableTypography.display(isTabletLayout ? .caption : .caption2, weight: .bold))
                    .foregroundStyle(hero.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(hero.title)
                    .font(TableTypography.display(isTabletLayout ? .largeTitle : .title2, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                Text(hero.detail)
                    .font(TableTypography.display(isTabletLayout ? .callout : .caption))
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trump = snapshot.trump {
                trumpChip(trump)
            }
        }
        .padding(isTabletLayout ? 18 : 14)
        .background {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .fill(hero.tint.opacity(0.10))
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.12), .clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: isTabletLayout ? 18 : 14, style: .continuous)
                .stroke(hero.tint.opacity(0.38), lineWidth: 1)
        }
    }

    private var scoreboardSection: some View {
        VStack(alignment: .leading, spacing: isTabletLayout ? 13 : 10) {
            HStack {
                Text("Scoreboard")
                    .font(TableTypography.display(isTabletLayout ? .headline : .subheadline, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("$1M target")
                    .font(TableTypography.money(isTabletLayout ? .caption : .caption2, weight: .regular))
                    .foregroundStyle(.white.opacity(0.64))
            }
            scoreRow(team: 0)
            Divider().overlay(.white.opacity(0.12))
            scoreRow(team: 1)
        }
        .padding(isTabletLayout ? 18 : 14)
        .sectionSurface(tint: .white.opacity(0.62), cornerRadius: isTabletLayout ? 18 : 14)
    }

    private var bidHistoryPanel: some View {
        DisclosureGroup(isExpanded: $bidHistoryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Opener: \(seatName(snapshot.opener))")
                    .font(TableTypography.display(.caption2, weight: .bold))
                    .foregroundStyle(TableStyle.cardSelected)
                FlowRow(spacing: 6) {
                    ForEach(Array(snapshot.bidHistory.enumerated()), id: \.offset) { index, record in
                        let firstMention = !snapshot.bidHistory[..<index].contains { $0.player == record.player }
                        HStack(spacing: 4) {
                            Text(seatShort(record.player))
                                .font(TableTypography.display(.caption2))
                                .foregroundStyle(.secondary)
                            if record.player == snapshot.opener && firstMention {
                                Text("opens")
                                    .font(TableTypography.display(.caption2))
                                    .foregroundStyle(TableStyle.cardSelected)
                            }
                            Text(bidHistoryLabel(record.action))
                                .font(TableTypography.money(.caption2))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(bidHistoryTint(record).opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(bidHistoryTint(record).opacity(0.45), lineWidth: 1))
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            bidHistorySummary
        }
        .font(TableTypography.display(.caption))
        .padding(isTabletLayout ? 12 : 10)
        .sectionSurface(tint: TableStyle.cardSelected, cornerRadius: isTabletLayout ? 16 : 12)
    }

    private var bidHistorySummary: some View {
        HStack(spacing: 8) {
            Text("Auction")
                .font(TableTypography.display(.caption, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text("\(snapshot.bidHistory.count) calls")
                .font(TableTypography.display(.caption2, weight: .bold))
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action {
            Button {
                SoundEffectPlayer.shared.play(.buttonSelect)
                action.action()
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .frame(maxWidth: isTabletLayout ? 280 : .infinity)
            }
            .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                              compact: !isTabletLayout))
            .padding(.top, isTabletLayout ? 4 : 2)
        }
    }

    private func scoreRow(team: Int) -> some View {
        let tint = TableStyle.teamTint(team)
        let captured = snapshot.handPoints(for: team) ?? 0
        let delta = snapshot.scoreDelta(for: team) ?? 0
        let previous = snapshot.previousMatchScore(for: team) ?? snapshot.matchScore[team, default: 0] - delta
        let final = snapshot.matchScore[team, default: 0]
        let previousProgress = progress(for: previous)
        let finalProgress = progress(for: final)
        let remaining = max(0, HandCompleteSnapshot.matchTarget - final)
        let isWinner = snapshot.matchWinner == team

        return VStack(alignment: .leading, spacing: isTabletLayout ? 9 : 7) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: isTabletLayout ? 12 : 10,
                           height: isTabletLayout ? 12 : 10)
                Text(teamName(team))
                    .font(TableTypography.display(isTabletLayout ? .headline : .subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 8)
                teamStatusBadge(team: team)
            }

            HStack(alignment: .firstTextBaseline, spacing: isTabletLayout ? 16 : 10) {
                scoreMetric("Captured", money(captured))
                scoreMetric(delta >= 0 ? "Earned" : "Lost",
                            money(delta, signed: true),
                            tint: delta >= 0 ? TableStyle.cardPlayable : TableStyle.teamAmber)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(final))
                        .font(TableTypography.money(isTabletLayout ? .title2 : .title3))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .layoutPriority(1)
                    Text(isWinner ? "won" : "\(money(remaining)) left")
                        .font(TableTypography.money(.caption2, weight: .regular))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(tint.opacity(0.26))
                        .frame(width: proxy.size.width * previousProgress)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * finalProgress)
                }
            }
            .frame(height: isTabletLayout ? 8 : 6)
        }
        .padding(.vertical, isTabletLayout ? 4 : 2)
    }

    private func teamStatusBadge(team: Int) -> some View {
        let isBidTeam = snapshot.biddingTeam == team
        let text: String
        let tint: Color
        if isBidTeam, let made = snapshot.madeBid {
            text = made ? "Made bid" : "Went set"
            tint = made ? TableStyle.cardPlayable : TableStyle.teamAmber
        } else if snapshot.bidAmount != nil {
            text = "Defended"
            tint = TableStyle.cardSelected
        } else {
            text = "Scored"
            tint = TableStyle.passGray
        }

        return Text(text)
            .font(TableTypography.display(.caption2, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().stroke(tint.opacity(0.42), lineWidth: 1))
    }

    private func scoreMetric(_ title: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(TableTypography.display(.caption2, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(TableTypography.money(isTabletLayout ? .title3 : .headline))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trumpChip(_ trump: CardColor) -> some View {
        let tint = TableStyle.suitSwatch(trump)
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
            Text(trump.displayName)
                .font(TableTypography.display(.caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(trump == .black ? 0.34 : 0.20)))
        .overlay(Capsule().stroke(tint.opacity(0.54), lineWidth: 1))
    }

    private var heroCopy: (eyebrow: String, title: String, detail: String, icon: String, tint: Color) {
        if let winner = snapshot.matchWinner {
            return ("Match complete",
                    "\(teamName(winner)) wins",
                    "First team to \(money(HandCompleteSnapshot.matchTarget)).",
                    "crown.fill",
                    TableStyle.tableGold)
        }

        if let bid = snapshot.bidAmount,
           let bidder = snapshot.bidder,
           let bidTeam = snapshot.biddingTeam,
           let made = snapshot.madeBid {
            if made {
                return ("Hand complete",
                        "Contract made",
                        "\(seatName(bidder)) bid \(money(bid)) for \(teamName(bidTeam)).",
                        "checkmark.seal.fill",
                        TableStyle.cardPlayable)
            } else {
                return ("Hand complete",
                        "Bid team went set",
                        "\(seatName(bidder)) bid \(money(bid)) for \(teamName(bidTeam)).",
                        "exclamationmark.triangle.fill",
                        TableStyle.teamAmber)
            }
        }

        return ("Hand complete",
                "Scores settled",
                "The match continues toward \(money(HandCompleteSnapshot.matchTarget)).",
                "flag.fill",
                TableStyle.cardSelected)
    }

    private func progress(for score: Int) -> CGFloat {
        CGFloat(min(1.0, max(0.0, Double(score) / Double(HandCompleteSnapshot.matchTarget))))
    }

    private func money(_ amount: Int, signed: Bool = false) -> String {
        let sign: String
        if signed {
            sign = amount > 0 ? "+" : (amount < 0 ? "-" : "")
        } else {
            sign = amount < 0 ? "-" : ""
        }
        return "\(sign)$\(abs(amount) / 1000)k"
    }

    private func bidHistoryLabel(_ action: BidAction) -> String {
        switch action {
        case .pass: return "Pass"
        case .bid(let amount): return money(amount)
        }
    }

    private func bidHistoryTint(_ record: BidRecord) -> Color {
        switch record.action {
        case .pass: return TableStyle.passGray
        case .bid: return TableStyle.tableGold
        }
    }
}

private extension View {
    func sectionSurface(tint: Color, cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.065))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.075))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }
}
