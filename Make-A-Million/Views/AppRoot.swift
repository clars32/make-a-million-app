//
//  AppRoot.swift
//  Make-a-Million
//
//  Top-level screen. Replaces the direct GameView entry point so we can
//  choose between solo and networked play before any game state exists.
//
//  THE THREE MODES, AND HOW THEY DIFFER:
//
//   • Solo     — the existing single-device flow. GameView observes a
//                GameSession that owns the runner; nothing changes vs
//                before this slice.
//   • Host     — this device runs the engine and accepts joiners over
//                MultipeerConnectivity. HostLobbyView owns the
//                MultipeerHost while the table is being set up; the
//                next slice will lift it out as the actual hand starts.
//   • Join     — this device is a client. ClientLobbyView owns the
//                MultipeerClient and, after a connection, hands off to
//                the client game view (also next slice).
//
//  Name handling: a single text field on the picker. The name is used
//  as the MCPeerID display name for both Host and Join (and for the
//  "South" label in the host's own seat list). Persisted via AppStorage
//  so it sticks across launches. Defaults to "Player" if blank — never
//  empty, because MCPeerID rejects empty strings.
//
//  Why no name field on the solo screen: solo has no peers and no
//  remote labels, so a name is just clutter you already see at seat 0.
//

import SwiftUI

struct AppRoot: View {

    enum Mode: Equatable {
        case picking
        case solo
        case hosting
        case joining
    }

    @State private var mode: Mode = .picking
    @State private var showingSettings = false
    @AppStorage("playerName") private var playerName: String = ""
    @EnvironmentObject private var settings: GameSettings

    var body: some View {
        Group {
            switch mode {
            case .picking:
                ModePickerView(
                    playerName: $playerName,
                    onPickSolo: { mode = .solo },
                    onPickHost: { mode = .hosting },
                    onPickJoin: { mode = .joining },
                    onOpenSettings: { showingSettings = true })

            case .solo:
                // GameView owns its own gear/Back chrome so the in-game
                // settings entry can lock rules while a hand is running.
                GameView(onExit: { mode = .picking })

            case .hosting:
                HostLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })

            case .joining:
                ClientLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })
            }
        }
        .sheet(isPresented: $showingSettings) {
            // Home-screen entry: no hand in progress, so rules are editable.
            SettingsView(settings: settings, rulesLocked: false) {
                showingSettings = false
            }
        }
    }

    private var effectiveName: String {
        let trimmed = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }
}

// MARK: - Mode picker

private struct ModePickerView: View {

    @Binding var playerName: String
    let onPickSolo: () -> Void
    let onPickHost: () -> Void
    let onPickJoin: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TableFeltBackground()

            VStack(spacing: 24) {
                Spacer(minLength: 8)

                VStack(spacing: 12) {
                    HomeHeroCards()
                        .frame(height: 168)
                        .padding(.bottom, 4)

                    Text("Make-a-Million")
                        .font(TableTypography.display(.largeTitle, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("A trick-taking card game")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name")
                        .font(.caption).foregroundStyle(.white.opacity(0.68))
                    TextField("Player", text: $playerName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                .padding(14)
                .tablePanel(cornerRadius: 14, shadowOpacity: 0.18)
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    ModeButton(
                        title: "Play Solo",
                        subtitle: "Just you against three bots",
                        systemImage: "person.fill",
                        color: TableStyle.actionBlue,
                        action: onPickSolo)
                    ModeButton(
                        title: "Host a Table",
                        subtitle: "Other devices nearby can join you",
                        systemImage: "wifi",
                        color: TableStyle.teamBlue,
                        action: onPickHost)
                    ModeButton(
                        title: "Join a Table",
                        subtitle: "Find a nearby host",
                        systemImage: "person.2.fill",
                        color: TableStyle.teamAmber,
                        action: onPickJoin)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(TableStyle.cardSelected)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(TableStyle.panelStroke, lineWidth: 1))
            }
            .padding()
            .accessibilityLabel("Settings")
        }
    }
}

private struct HomeHeroCards: View {
    private let cards: [Card] = [
        .colored(.green, .money40k),
        .bull,
        .colored(.yellow, .money30k),
        .tiger
    ]

    var body: some View {
        ZStack {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                CardFace(card: card, width: 74, height: 104)
                    .rotationEffect(.degrees(rotation(for: index)))
                    .offset(x: xOffset(for: index), y: yOffset(for: index))
                    .zIndex(Double(index))
            }
        }
        .accessibilityHidden(true)
    }

    private func rotation(for index: Int) -> Double {
        [-13, -4, 6, 14][index]
    }

    private func xOffset(for index: Int) -> CGFloat {
        [-84, -28, 30, 86][index]
    }

    private func yOffset(for index: Int) -> CGFloat {
        [12, -8, -2, 16][index]
    }
}

private struct ModeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(color)
                    .background(Circle().fill(color.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.70))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.52))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .tablePanel(cornerRadius: 14, shadowOpacity: 0.22)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(color.opacity(0.42), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
