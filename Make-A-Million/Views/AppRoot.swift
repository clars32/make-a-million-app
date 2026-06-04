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
            LinearGradient(
                colors: [Color.teal.opacity(0.2), Color.blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(height: 12)

                VStack(spacing: 6) {
                    Text("Make-a-Million")
                        .font(.largeTitle).bold()
                    Text("A trick-taking card game")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Player", text: $playerName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    ModeButton(
                        title: "Play Solo",
                        subtitle: "Just you against three bots",
                        systemImage: "person.fill",
                        color: .blue,
                        action: onPickSolo)
                    ModeButton(
                        title: "Host a Table",
                        subtitle: "Other devices nearby can join you",
                        systemImage: "wifi",
                        color: .green,
                        action: onPickHost)
                    ModeButton(
                        title: "Join a Table",
                        subtitle: "Find a nearby host",
                        systemImage: "person.2.fill",
                        color: .orange,
                        action: onPickJoin)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Settings")
        }
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
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color))
        }
        .buttonStyle(.plain)
    }
}
