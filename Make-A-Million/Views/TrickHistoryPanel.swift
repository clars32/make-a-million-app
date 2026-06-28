//
//  TrickHistoryPanel.swift
//  Make-a-Million
//
//  Compact public trick history, opened from a seat chip when the display
//  setting is enabled.
//

import SwiftUI

struct TrickHistoryPanel: View {
    let seat: PlayerID
    let completedTricks: [CompletedTrickInfo]
    let seatName: (PlayerID) -> String
    let seatShort: (PlayerID) -> String
    var miniCardWidth: CGFloat = 46
    var miniCardHeight: CGFloat = 32
    var maxHeight: CGFloat = 280
    let onClose: () -> Void

    private var wonTricks: [(number: Int, trick: CompletedTrickInfo)] {
        completedTricks.enumerated().compactMap { index, trick in
            trick.winner == seat ? (index + 1, trick) : nil
        }
    }

    private var totalValue: Int {
        wonTricks.reduce(0) { $0 + $1.trick.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if wonTricks.isEmpty {
                Text("No tricks taken yet.")
                    .font(TableTypography.display(.callout))
                    .foregroundStyle(.white.opacity(0.64))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(wonTricks, id: \.number) { item in
                            trickRow(number: item.number, trick: item.trick)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: maxHeight)
                .scrollIndicators(.hidden)
            }
        }
        .padding(14)
        .frame(maxWidth: 480)
        .tablePanel(cornerRadius: 18, shadowOpacity: 0.32)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(seatName(seat))'s tricks")
                    .font(TableTypography.display(.headline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(wonTricks.count) trick\(wonTricks.count == 1 ? "" : "s") · $\(totalValue / 1000)k")
                    .font(TableTypography.money(.caption))
                    .foregroundStyle(TableStyle.tableGold)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(TableTypography.display(.caption, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close trick history")
        }
    }

    private func trickRow(number: Int, trick: CompletedTrickInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(number)")
                    .font(TableTypography.money(.caption))
                    .foregroundStyle(.white.opacity(0.86))
                Text("$\(trick.value / 1000)k")
                    .font(TableTypography.money(.caption2))
                    .foregroundStyle(TableStyle.tableGold)
            }
            .frame(width: 46, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(keyedPlays(trick.plays), id: \.key) { entry in
                    MiniCardFace(card: entry.play.card,
                                 faded: entry.play.player != seat,
                                 width: miniCardWidth,
                                 height: miniCardHeight)
                        .accessibilityLabel("\(seatShort(entry.play.player))")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
