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
            // Check if we are connected and have an active game frame
            if case .connected(let peerName) = multipeer.state, let session = clientSession, session.displayView != nil {
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
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.orange.opacity(0.16), Color.yellow.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Join a table").font(.system(.title2, design: .rounded)).bold()
                Text("Searching as \(playerName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back") {
                multipeer.stop()
                onExit()
            }
            .buttonStyle(.bordered)
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
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProgressView().scaleEffect(0.7)
            }

            if multipeer.discovered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange.opacity(0.8))
                        .scaleEffect(isSearching ? 1.1 : 0.9)
                        .opacity(isSearching ? 1.0 : 0.5)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                isSearching = true
                            }
                        }
                    Text("Looking for tables…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .italic()
                    Text("Make sure the host has tapped “Host a Table.”")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
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
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName).font(.headline)
                    Text("Tap to join")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.opacity(0.7)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func connectingView(peerName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.4)
            Text("Connecting to \(peerName)…")
                .font(.headline)
            Text("The host has to accept your invitation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func connectedView(peerName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text("Waiting for host to start…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .onAppear {
            guard clientSession == nil, let t = multipeer.transport else { return }
            let session = ClientSession(transport: t)
            clientSession = session
            session.start()
            session.introduce(name: playerName)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try again") {
                multipeer.startBrowsing()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
