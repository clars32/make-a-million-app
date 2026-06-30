//
//  BotDifficultyPicker.swift
//  Make-a-Million
//
//  Compact difficulty control for the host lobbies. Multiplayer fills every
//  empty seat with a bot at `GameSettings.botDifficulty` (re-read at each deal),
//  so binding this straight to the shared settings is enough — no per-session
//  plumbing. The full Adaptive (experimental) door stays in the Settings sheet;
//  the lobby just exposes the four legible ladder rungs.
//

import SwiftUI

struct BotDifficultyPicker: View {
    @ObservedObject var settings: GameSettings

    /// The ladder rung the control reflects. If Adaptive happens to be on,
    /// show the remembered rung and let a tap drop back onto the ladder.
    private var tierBinding: Binding<MonteCarloAgent.Difficulty.Level> {
        Binding(
            get: {
                settings.aiDifficulty.isAdaptive ? settings.lastLadderTier
                                                 : settings.aiDifficulty
            },
            set: { settings.aiDifficulty = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(TableTypography.display(.caption, weight: .bold))
                    .foregroundStyle(TableStyle.cardSelected)
                Text("Bot difficulty")
                    .font(TableTypography.display(.subheadline, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(tierBinding.wrappedValue.displayName.capitalized)
                    .font(TableTypography.display(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            // A custom segmented control: the system `.segmented` style forces
            // black-on-white, which fights the dark felt. White labels with a
            // blue highlight match the rest of the table chrome instead.
            HStack(spacing: 4) {
                ForEach(MonteCarloAgent.Difficulty.Level.ladder) { level in
                    let selected = level == tierBinding.wrappedValue
                    Text(level.displayName.capitalized)
                        .font(TableTypography.display(.caption, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(TableStyle.actionBlue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            SoundEffectPlayer.shared.play(.buttonSelect)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                tierBinding.wrappedValue = level
                            }
                        }
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(TableStyle.panelStroke, lineWidth: 1))
            Text("Bots that fill empty seats play at this strength.")
                .font(TableTypography.display(.caption2))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(14)
        .tablePanel(cornerRadius: 14, shadowOpacity: 0.18)
    }
}
