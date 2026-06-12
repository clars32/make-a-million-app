//
//  OnlineClientLobbyView.swift
//  Make-a-Million
//
//  Client-side lobby for a remote (internet) table. Sibling of
//  ClientLobbyView, with the connection layer swapped: instead of
//  browsing for nearby hosts, the player gets here by accepting a Game
//  Center invite (or by tapping "Join Online" and waiting for one to
//  arrive). The invite resolves to a GKMatch; once the host is
//  connected we hand off to the same ClientGameView the nearby flow
//  uses — ClientSession neither knows nor cares which transport feeds
//  it.
//
//  Two entry paths converge here:
//
//   • Invite-first: the player accepts a Game Center notification.
//     GameCenterManager publishes the accepted invite, AppRoot routes
//     to this view, and we connect immediately.
//   • App-first: the player taps "Join Online" with no invite yet. We
//     show a waiting room (and the sign-in affordance if needed); the
//     moment an invite is accepted, the same publisher fires and we
//     connect.
//

import SwiftUI

struct OnlineClientLobbyView: View {

    let onExit: () -> Void

    @ObservedObject private var gameCenter = GameCenterManager.shared
    @State private var client: GameCenterClient? = nil
    @State private var clientSession: ClientSession? = nil

    // UI animation state for the waiting room.
    @State private var isSearching = false

    var body: some View {
        Group {
            if let client, let session = clientSession {
                ConnectedContent(
                    client: client,
                    session: session,
                    onExit: { teardown(); onExit() })
            } else {
                waitingRoom
            }
        }
        .onAppear {
            BackgroundMusicPlayer.shared.setGameActive(false)
            BackgroundMusicPlayer.shared.playLobbyMusic()
            gameCenter.configureAuthentication()
            connectIfInvited()
        }
        .onChange(of: gameCenter.acceptedInvite) { _, _ in
            connectIfInvited()
        }
        .onDisappear {
            // Covers system-driven dismissals; teardown is idempotent.
            teardown()
        }
    }

    /// Bind a fresh GameCenterClient + ClientSession to the accepted
    /// invite's match. Replaces any previous pair outright — an old
    /// session is tied to a dead match.
    private func connectIfInvited() {
        guard let invite = gameCenter.acceptedInvite else { return }
        clientSession?.stop()
        client?.stop()

        let c = GameCenterClient(match: invite.match, host: invite.host)
        client = c
        guard let transport = c.transport else { return }
        let session = ClientSession(transport: transport)
        clientSession = session
        session.start()
        session.introduce(name: gameCenter.localDisplayName)
    }

    private func teardown() {
        clientSession?.stop()
        clientSession = nil
        client?.stop()
        client = nil
        // The match is dead once we leave; don't let a stale invite
        // reconnect us to it on re-entry.
        gameCenter.acceptedInvite = nil
    }

    // MARK: - Waiting room (no invite yet)

    private var waitingRoom: some View {
        ZStack {
            TableFeltBackground()
            VStack(alignment: .leading, spacing: 18) {
                header
                waitingContent
                Spacer()
            }
            .padding()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Join online")
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text("Play over the internet via Game Center")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button("Back") {
                teardown()
                onExit()
            }
            .buttonStyle(.bordered)
            .tint(TableStyle.teamAmber)
        }
    }

    @ViewBuilder
    private var waitingContent: some View {
        switch gameCenter.authState {
        case .authenticated:
            VStack(spacing: 10) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 40))
                    .foregroundStyle(TableStyle.teamAmber.opacity(0.90))
                    .scaleEffect(isSearching ? 1.1 : 0.9)
                    .opacity(isSearching ? 1.0 : 0.5)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            isSearching = true
                        }
                    }
                Text("Waiting for an invitation…")
                    .font(TableTypography.display(.callout))
                    .foregroundStyle(.white.opacity(0.52))
                    .italic()
                Text("Ask the host to invite you from their online table. You can also accept the invite straight from the Game Center notification — it will bring you here.")
                    .font(TableTypography.display(.caption2))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                if let error = gameCenter.inviteError {
                    Text(error)
                        .font(TableTypography.display(.caption))
                        .foregroundStyle(TableStyle.teamAmber)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)

        case .unknown:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8).tint(TableStyle.tableGold)
                Text("Checking Game Center…")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)

        case .needsSignIn:
            VStack(spacing: 12) {
                Text("Online play uses Game Center to receive invitations.")
                    .font(TableTypography.display(.callout))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                Button("Sign in to Game Center") {
                    gameCenter.presentSignIn()
                }
                .buttonStyle(.borderedProminent)
                .tint(TableStyle.actionBlue)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(TableStyle.teamAmber)
                Text(message)
                    .font(TableTypography.display(.callout))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
        }
    }
}

// MARK: - Connected content

/// Inner view so the GKMatch connection state and the session are
/// actually observed — the parent holds them in @State, which would not
/// re-render on their @Published changes.
private struct ConnectedContent: View {

    @ObservedObject var client: GameCenterClient
    @ObservedObject var gameCenter = GameCenterManager.shared
    let session: ClientSession
    let onExit: () -> Void

    init(client: GameCenterClient, session: ClientSession, onExit: @escaping () -> Void) {
        self.client = client
        self.session = session
        self.onExit = onExit
    }

    var body: some View {
        switch client.state {
        case .connected:
            ClientGameView(
                playerName: gameCenter.localDisplayName,
                hostName: client.hostName,
                session: session,
                onExit: onExit)
            .onAppear { BackgroundMusicPlayer.shared.setGameActive(true) }

        case .connecting:
            ZStack {
                TableFeltBackground()
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(TableStyle.tableGold)
                    Text("Connecting to \(client.hostName)…")
                        .font(TableTypography.display(.headline, weight: .bold))
                        .foregroundStyle(.white)
                    Button("Cancel") { onExit() }
                        .buttonStyle(.bordered)
                        .tint(TableStyle.teamAmber)
                }
                .padding(24)
                .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
            }
            .onAppear {
                BackgroundMusicPlayer.shared.setGameActive(false)
                BackgroundMusicPlayer.shared.playLobbyMusic()
            }

        case .failed(let message):
            ZStack {
                TableFeltBackground()
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(TableStyle.teamAmber)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .font(TableTypography.display(.callout))
                        .foregroundStyle(.white.opacity(0.68))
                    Button("Back") { onExit() }
                        .buttonStyle(.borderedProminent)
                        .tint(TableStyle.actionBlue)
                }
                .padding(24)
                .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
            }
            .onAppear {
                BackgroundMusicPlayer.shared.setGameActive(false)
                BackgroundMusicPlayer.shared.playLobbyMusic()
            }
        }
    }
}
