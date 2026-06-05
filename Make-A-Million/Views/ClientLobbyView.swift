//
//  ClientLobbyView.swift
//  Make-a-Million
//

import SwiftUI
import MultipeerConnectivity

struct ClientLobbyView: View {

    let playerName: String
    let onExit: () -> Void

    @StateObject private var multipeer: MultipeerClient
    @State private var clientSession: ClientSession? = nil
    
    // UI Animation State
    @State private var isSearching = false

    init(playerName: String, onExit: @escaping () -> Void) {
        self.playerName = playerName
        self.onExit = onExit
        _multipeer = StateObject(
            wrappedValue: MultipeerClient(displayName: playerName))
    }

    var body: some View {
        Group {
            // Once connected with a live session, hand off to the game
            // view. Don't gate on session.displayView here: clientSession
            // is held in @State, which does NOT observe the session's
            // @Published properties, so a displayView change would never
            // re-render this view and we'd stay stuck on the lobby.
            // ClientGameView (@ObservedObject) shows its own "Waiting for
            // the table…" state until the first frame arrives.
            if case .connected(let peerName) = multipeer.state, let session = clientSession {
                ClientGameView(
                    playerName: playerName,
                    hostName: peerName.displayName, // Pass the host's peer name here
                    session: session,
                    onExit: {
                        session.stop()
                        multipeer.stop()
                        clientSession = nil
                        onExit()
                    }
                )
            } else {
                // Otherwise, show the normal Lobby UI
                ZStack {
                    background
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        content
                        Spacer()
                    }
                    .padding()
                }
            }
        }
        .onAppear { multipeer.startBrowsing() }
        .onDisappear { multipeer.stop() }
        .onChange(of: multipeer.state) { _, newState in
            switch newState {
            case .connected:
                // Bind a fresh ClientSession to the (possibly brand-new,
                // post-reconnect) transport. The old session, if any, is
                // tied to a dead transport, so replace it outright.
                guard let t = multipeer.transport else { return }
                clientSession?.stop()
                let session = ClientSession(transport: t)
                clientSession = session
                session.start()
                session.introduce(name: playerName)
            case .failed, .idle:
                clientSession?.stop()
                clientSession = nil
            case .browsing, .connecting:
                break
            }
        }
    }

    private var background: some View {
        TableFeltBackground()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Join a table")
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text("Searching as \(playerName)")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button("Back") {
                multipeer.stop()
                onExit()
            }
            .buttonStyle(.bordered)
            .tint(TableStyle.teamAmber)
        }
    }

    // MARK: Content per connection state

    @ViewBuilder
    private var content: some View {
        switch multipeer.state {
        case .idle, .browsing:
            browsingList
        case .connecting(let peer):
            connectingView(peerName: peer.displayName)
        case .connected(let peer):
            connectedView(peerName: peer.displayName)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private var browsingList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nearby tables")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                ProgressView().scaleEffect(0.7)
                    .tint(TableStyle.tableGold)
            }

            if multipeer.discovered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(TableStyle.teamAmber.opacity(0.90))
                        .scaleEffect(isSearching ? 1.1 : 0.9)
                        .opacity(isSearching ? 1.0 : 0.5)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                isSearching = true
                            }
                        }
                    Text("Looking for tables…")
                        .font(TableTypography.display(.callout))
                        .foregroundStyle(.white.opacity(0.52))
                        .italic()
                    Text("Make sure the host has tapped “Host a Table.”")
                        .font(TableTypography.display(.caption2))
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
            } else {
                VStack(spacing: 8) {
                    ForEach(multipeer.discovered) { host in
                        hostRow(host)
                    }
                }
            }
        }
    }

    private func hostRow(_ host: MultipeerClient.DiscoveredHost) -> some View {
        Button {
            multipeer.join(host)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(TableStyle.teamAmber)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .font(TableTypography.display(.headline, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tap to join")
                        .font(TableTypography.display(.caption))
                        .foregroundStyle(.white.opacity(0.60))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.46))
            }
            .padding(12)
            .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TableStyle.teamAmber.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func connectingView(peerName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.4).tint(TableStyle.tableGold)
            Text("Connecting to \(peerName)…")
                .font(TableTypography.display(.headline, weight: .bold))
                .foregroundStyle(.white)
            Text("The host has to accept your invitation.")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
    }

    private func connectedView(peerName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2).tint(TableStyle.tableGold)
            Text("Waiting for host to start…")
                .font(TableTypography.display(.headline, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(TableStyle.teamAmber)
            Text(message).multilineTextAlignment(.center)
                .font(TableTypography.display(.callout))
                .foregroundStyle(.white.opacity(0.68))
            Button("Try again") {
                multipeer.startBrowsing()
            }
            .buttonStyle(.borderedProminent)
            .tint(TableStyle.actionBlue)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .tablePanel(cornerRadius: 16, shadowOpacity: 0.16)
    }
}
