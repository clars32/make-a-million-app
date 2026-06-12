//
//  AppRoot.swift
//  Make-a-Million
//
//  Top-level screen. Replaces the direct GameView entry point so we can
//  choose between solo and networked play before any game state exists.
//
//  TOP-LEVEL FLOW:
//
//   • Home: Solo / Join / Host.
//   • Join: Join Online / Join Local.
//   • Host: Host Local / Host Tabletop / Host Online.
//
//  Local Host/Join use MultipeerConnectivity. Online Host/Join use Game
//  Center. Tabletop hosting uses the same host lobby but starts in spectator
//  board mode so all four seats are filled by nearby clients.
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
        case pickingJoin
        case pickingHost
        case solo
        case hostingLocal
        case hostingTabletop
        case joiningLocal
        case hostingOnline
        case joiningOnline
    }

    @State private var mode: Mode = .picking
    @State private var showingSettings = false
    @AppStorage("playerName") private var playerName: String = ""
    @EnvironmentObject private var settings: GameSettings
    @ObservedObject private var gameCenter = GameCenterManager.shared

    var body: some View {
        Group {
            switch mode {
            case .picking:
                ModePickerView(
                    playerName: $playerName,
                    onPickSolo: { mode = .solo },
                    onPickJoin: { mode = .pickingJoin },
                    onPickHost: { mode = .pickingHost },
                    onOpenSettings: { showingSettings = true })

            case .pickingJoin:
                JoinPickerView(
                    playerName: $playerName,
                    onPickOnline: { mode = .joiningOnline },
                    onPickLocal: { mode = .joiningLocal },
                    onBack: { mode = .picking },
                    onOpenSettings: { showingSettings = true })

            case .pickingHost:
                HostPickerView(
                    playerName: $playerName,
                    onPickLocal: { mode = .hostingLocal },
                    onPickTabletop: { mode = .hostingTabletop },
                    onPickOnline: { mode = .hostingOnline },
                    onBack: { mode = .picking },
                    onOpenSettings: { showingSettings = true })

            case .solo:
                // GameView owns its own gear/Back chrome so the in-game
                // settings entry can lock rules while a hand is running.
                GameView(onExit: { mode = .picking })

            case .hostingLocal:
                HostLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })

            case .hostingTabletop:
                TabletopHostLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })

            case .joiningLocal:
                ClientLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })

            case .hostingOnline:
                OnlineHostLobbyView(
                    playerName: effectiveName,
                    onExit: { mode = .picking })

            case .joiningOnline:
                OnlineClientLobbyView(
                    onExit: { mode = .picking })
            }
        }
        .onAppear {
            #if canImport(UIKit)
            OrientationLock.shared.lock(.portrait)
            #endif
            // Install the Game Center authenticate handler early so an
            // invite that launches the app is caught no matter what
            // screen is showing. Sign-in UI stays deferred until the
            // user actually enters an online mode.
            gameCenter.configureAuthentication()
        }
        .onChange(of: gameCenter.acceptedInvite) { _, invite in
            // An accepted invite routes to the online client lobby — but
            // never yank the player out of a running mode; if they're
            // mid-hand the invite stays pending and connects if they
            // enter "Join Online" themselves.
            if invite != nil && (mode == .picking || mode == .pickingJoin) {
                mode = .joiningOnline
            }
        }
        .onChange(of: mode) { _, mode in
            #if canImport(UIKit)
            if mode != .hostingTabletop {
                OrientationLock.shared.lock(.portrait)
            }
            #endif
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
    let onPickJoin: () -> Void
    let onPickHost: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HomeMenuShell(
            playerName: $playerName,
            title: "Make-a-Million",
            subtitle: "A classic Packard trick-taking card game",
            showsHero: true,
            showsPlayerName: false,
            systemImage: "suit.club.fill",
            onBack: nil,
            onOpenSettings: onOpenSettings) {
                ModeButton(
                    title: "Solo",
                    subtitle: "Play a full table against three bots",
                    systemImage: "person.fill",
                    color: TableStyle.actionBlue,
                    action: onPickSolo)
                ModeButton(
                    title: "Join",
                    subtitle: "Find a local table or accept an online invite",
                    systemImage: "person.2.fill",
                    color: TableStyle.teamAmber,
                    action: onPickJoin)
                ModeButton(
                    title: "Host",
                    subtitle: "Start a local, tabletop, or online table",
                    systemImage: "rectangle.connected.to.line.below",
                    color: TableStyle.teamBlue,
                    action: onPickHost)
        }
    }
}

private struct JoinPickerView: View {
    @Binding var playerName: String
    let onPickOnline: () -> Void
    let onPickLocal: () -> Void
    let onBack: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HomeMenuShell(
            playerName: $playerName,
            title: "Join",
            subtitle: "Connect to someone else's table",
            showsHero: false,
            systemImage: "person.2.fill",
            onBack: onBack,
            onOpenSettings: onOpenSettings) {
                ModeButton(
                    title: "Join Local",
                    subtitle: "Find a nearby host on this Wi-Fi",
                    systemImage: "antenna.radiowaves.left.and.right",
                    color: TableStyle.teamAmber,
                    action: onPickLocal)
                ModeButton(
                    title: "Join Online",
                    subtitle: "Use Game Center to connect anywhere",
                    systemImage: "globe.americas.fill",
                    color: TableStyle.teamBlue,
                    action: onPickOnline)
        }
    }
}

private struct HostPickerView: View {
    @Binding var playerName: String
    let onPickLocal: () -> Void
    let onPickTabletop: () -> Void
    let onPickOnline: () -> Void
    let onBack: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HomeMenuShell(
            playerName: $playerName,
            title: "Host",
            subtitle: "Choose what kind of table to run",
            showsHero: false,
            systemImage: "rectangle.connected.to.line.below",
            onBack: onBack,
            onOpenSettings: onOpenSettings) {
                ModeButton(
                    title: "Host Local",
                    subtitle: "Nearby devices fill seats",
                    systemImage: "wifi",
                    color: TableStyle.teamBlue,
                    action: onPickLocal)
                ModeButton(
                    title: "Host Tabletop",
                    subtitle: "Use this device as the shared board",
                    systemImage: "rectangle.on.rectangle.angled",
                    color: TableStyle.tableGold,
                    action: onPickTabletop)
                ModeButton(
                    title: "Host Online",
                    subtitle: "Invite friends with Game Center",
                    systemImage: "globe",
                    color: TableStyle.teamAmber,
                    action: onPickOnline)
        }
    }
}

private struct HomeMenuShell<Content: View>: View {
    @Binding var playerName: String
    let title: String
    let subtitle: String
    let showsHero: Bool
    let showsPlayerName: Bool
    let systemImage: String
    let onBack: (() -> Void)?
    let onOpenSettings: () -> Void
    let content: Content

    init(
        playerName: Binding<String>,
        title: String,
        subtitle: String,
        showsHero: Bool,
        showsPlayerName: Bool = true,
        systemImage: String,
        onBack: (() -> Void)?,
        onOpenSettings: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _playerName = playerName
        self.title = title
        self.subtitle = subtitle
        self.showsHero = showsHero
        self.showsPlayerName = showsPlayerName
        self.systemImage = systemImage
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let isTablet = proxy.size.width >= 700
            let isHome = showsHero && !showsPlayerName && onBack == nil
            let contentWidth: CGFloat = isTablet ? min(proxy.size.width * 0.58, 560) : min(proxy.size.width - 32, 430)
            let heroHeight: CGFloat = isHome
                ? (isTablet ? min(proxy.size.height * 0.34, 350) : min(max(proxy.size.height * 0.28, 212), 260))
                : (isTablet ? min(proxy.size.height * 0.28, 310) : 198)
            let heroScale: CGFloat = isHome
                ? (isTablet ? 1.92 : 1.34)
                : (isTablet ? 1.72 : 1.18)
            let topInset: CGFloat = isHome ? (isTablet ? 34 : 26) : (isTablet ? 28 : 8)
            let headerSpacing: CGFloat = isHome ? (isTablet ? 18 : 14) : 12
            let sectionSpacing: CGFloat = isHome ? (isTablet ? 34 : 28) : (isTablet ? 28 : 22)
            let buttonSpacing: CGFloat = isHome ? (isTablet ? 14 : 12) : 10
            let bottomInset: CGFloat = isHome ? (isTablet ? 40 : 32) : 16

            ZStack(alignment: .top) {
                TableFeltBackground()

                ScrollView {
                    VStack(spacing: sectionSpacing) {
                        Spacer(minLength: topInset)

                        VStack(spacing: headerSpacing) {
                            if showsHero {
                                HomeHeroCards(scale: heroScale)
                                    .frame(height: heroHeight)
                                    .padding(.bottom, isHome ? 8 : 4)
                            } else {
                                Image(systemName: systemImage)
                                    .font(.system(size: isTablet ? 64 : 46, weight: .semibold))
                                    .foregroundStyle(TableStyle.tableGold)
                                    .frame(height: isTablet ? 94 : 66)
                            }

                            Text(title)
                                .font(TableTypography.display(.largeTitle, weight: .heavy))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            Text(subtitle)
                                .font(TableTypography.display(.subheadline))
                                .foregroundStyle(.white.opacity(0.66))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: contentWidth)
                        .padding(.horizontal)

                        if showsPlayerName {
                            PlayerNamePanel(playerName: $playerName)
                                .frame(maxWidth: contentWidth)
                                .padding(.horizontal)
                        }

                        VStack(spacing: buttonSpacing) {
                            content
                        }
                        .frame(maxWidth: contentWidth)
                        .padding(.horizontal)

                        Spacer(minLength: bottomInset)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                    .padding(.vertical)
                }

                HStack {
                    if let onBack {
                        Button {
                            SoundEffectPlayer.shared.play(.buttonSelect)
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(TableTypography.display(.title3, weight: .bold))
                                .foregroundStyle(TableStyle.cardSelected)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(TableStyle.panelStroke, lineWidth: 1))
                        }
                        .accessibilityLabel("Back")
                    }

                    Spacer()

                    Button {
                        SoundEffectPlayer.shared.play(.buttonSelect)
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(TableTypography.display(.title3))
                            .foregroundStyle(TableStyle.cardSelected)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(TableStyle.panelStroke, lineWidth: 1))
                    }
                    .accessibilityLabel("Settings")
                }
                .padding()
            }
        }
    }
}

private struct PlayerNamePanel: View {
    @Binding var playerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your name")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.68))
            TextField("Player", text: $playerName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
        }
        .padding(14)
        .tablePanel(cornerRadius: 14, shadowOpacity: 0.18)
    }
}

private struct HomeHeroCards: View {
    var scale: CGFloat = 1.0

    private let cards: [Card] = [
        .colored(.green, .money40k),
        .bull,
        .colored(.yellow, .money30k),
        .tiger
    ]

    var body: some View {
        ZStack {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                CardFace(card: card, width: 74 * scale, height: 104 * scale)
                    .rotationEffect(.degrees(rotation(for: index)))
                    .offset(x: xOffset(for: index) * scale, y: yOffset(for: index) * scale)
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
        Button {
            SoundEffectPlayer.shared.play(.buttonSelect)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(TableTypography.display(.title2))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(color)
                    .background(Circle().fill(color.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TableTypography.display(.headline, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(TableTypography.display(.caption))
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
