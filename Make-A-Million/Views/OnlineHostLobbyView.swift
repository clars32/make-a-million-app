//
//  OnlineHostLobbyView.swift
//  Make-a-Million
//
//  Host-side lobby for a remote (internet) table. Sibling of
//  HostLobbyView, with the connection layer swapped: players arrive
//  through Game Center invites instead of local-network discovery, and
//  there is no tabletop option (that is a same-room feature — online
//  tables always seat the host at South).
//
//  A dropped remote player cannot rejoin a GKMatch, so unlike the
//  nearby lobby there is no reconnect wiring here; mid-hand drops land
//  in NetSession's pause overlay where the host fills the seat with a
//  bot.
//

import SwiftUI

struct OnlineHostLobbyView: View {

    let playerName: String
    let onExit: () -> Void

    @ObservedObject private var gameCenter = GameCenterManager.shared
    @ObservedObject private var settings = GameSettings.shared
    @StateObject private var host = GameCenterHost()
    @StateObject private var gameSession: GameSession
    @StateObject private var netSession: NetSession

    @State private var didStartHand: Bool = false
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)
    @State private var showingSettings = false
    @State private var bridgeToken: AnyObject? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// seat raw value → gamePlayerID, for seats 1–3. Seat 0 is always
    /// the host. Cleared when a player drops before the deal.
    @State private var seatAssignments: [Int: String] = [:]

    init(playerName: String, onExit: @escaping () -> Void) {
        self.playerName = playerName
        self.onExit = onExit
        let gs = GameSession()
        _gameSession = StateObject(wrappedValue: gs)
        // Bot strength follows the player's Settings → Opponents choice.
        _netSession = StateObject(wrappedValue: NetSession(
            hostRole: .player(seat: PlayerID(0), human: gs.human, name: playerName),
            botDifficulty: GameSettings.shared.botDifficulty))
    }

    var body: some View {
        ZStack {
            TableFeltBackground()

            if didStartHand {
                HostGameView(
                    netSession: netSession,
                    gameSession: gameSession,
                    human: gameSession.human,
                    onExit: {
                        netSession.stop()
                        host.stop()
                        onExit()
                    })
                .transition(TableMotion.screenTransition(reduceMotion: reduceMotion))
                .zIndex(1)
            } else {
                lobbyContent
                    .transition(TableMotion.screenTransition(reduceMotion: reduceMotion))
                    .zIndex(0)
            }
        }
        .animation(TableMotion.screenAnimation(reduceMotion: reduceMotion),
                   value: didStartHand)
        .onAppear {
            if !didStartHand {
                BackgroundMusicPlayer.shared.setGameActive(false)
                BackgroundMusicPlayer.shared.playLobbyMusic()
            }
            gameCenter.configureAuthentication()
        }
        .onDisappear {
            if !didStartHand { host.stop() }
        }
        .onChange(of: host.connectedPlayers) { _, _ in
            maintainSeatAssignments()
        }
    }

    private var lobbyContent: some View {
        // Header and Start button stay pinned; the table details scroll so the
        // full lobby (invite + seats + bot difficulty) fits any screen.
        VStack(spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusPanel
                    if gameCenter.authState == .authenticated {
                        invitePanel
                        seatList
                        BotDifficultyPicker(settings: settings)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            if gameCenter.authState == .authenticated {
                startButton
            }
        }
        .padding()
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your online table")
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text("Hosted by \(playerName)")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(TableIconButtonStyle(tint: TableStyle.cardSelected,
                                              size: 38))
            .accessibilityLabel("Settings")
            Button {
                host.stop()
                onExit()
            } label: {
                Label("Stop", systemImage: "xmark")
            }
            .buttonStyle(TablePillButtonStyle(tint: TableStyle.teamAmber,
                                              emphasis: .tinted,
                                              compact: true))
        }
        .sheet(isPresented: $showingSettings) {
            // Pre-match: rules are editable here and apply to the first deal.
            SettingsView(settings: .shared, rulesLocked: false) {
                showingSettings = false
            }
        }
    }

    // MARK: Game Center status

    @ViewBuilder
    private var statusPanel: some View {
        switch gameCenter.authState {
        case .authenticated:
            HStack(spacing: 8) {
                Circle()
                    .fill(TableStyle.cardPlayable)
                    .frame(width: 8, height: 8)
                Text("Signed in to Game Center as \(gameCenter.localDisplayName)")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(12)
            .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)

        case .unknown:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8).tint(TableStyle.tableGold)
                Text("Checking Game Center…")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(12)
            .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)

        case .needsSignIn:
            VStack(alignment: .leading, spacing: 10) {
                Text("Online play uses Game Center to invite friends.")
                    .font(TableTypography.display(.callout))
                    .foregroundStyle(.white.opacity(0.78))
                Button("Sign in to Game Center") {
                    gameCenter.presentSignIn()
                }
                .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue,
                                                  compact: true))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Game Center unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(TableTypography.display(.callout, weight: .bold))
                    .foregroundStyle(TableStyle.teamAmber)
                Text(message)
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
        }
    }

    // MARK: Invites

    private var invitePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                host.presentInviteSheet()
            } label: {
                Label(host.hasMatch ? "Invite more players" : "Invite players",
                      systemImage: "envelope.fill")
                    .font(TableTypography.display(.callout, weight: .bold))
            }
            .buttonStyle(TablePillButtonStyle(tint: TableStyle.teamBlue,
                                              compact: true))

            Text(host.connectedPlayers.isEmpty
                 ? "Invites go out over Game Center — friends can accept from anywhere."
                 : "\(host.connectedPlayers.count) player\(host.connectedPlayers.count == 1 ? "" : "s") connected. Empty seats get bots.")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.62))

            if let error = host.lastError {
                Text(error)
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(TableStyle.teamAmber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
    }

    // MARK: Seat list & assignments

    /// Drop assignments whose player left; auto-seat newcomers into the
    /// first open seat (1–3). Same policy as the nearby lobby.
    private func maintainSeatAssignments() {
        let connectedIDs = Set(host.connectedPlayers.map(\.id))
        for (seatRaw, playerID) in seatAssignments {
            if !connectedIDs.contains(playerID) { seatAssignments[seatRaw] = nil }
        }

        let assignedIDs = Set(seatAssignments.values)
        let availableSeats = [1, 2, 3]
        for player in host.connectedPlayers where !assignedIDs.contains(player.id) {
            if let emptySeat = availableSeats.first(where: { seatAssignments[$0] == nil }) {
                seatAssignments[emptySeat] = player.id
            }
        }
    }

    private var seatList: some View {
        VStack(spacing: 8) {
            ForEach(Seats.all, id: \.raw) { seat in
                seatRow(seat)
            }
        }
    }

    @ViewBuilder
    private func seatRow(_ seat: PlayerID) -> some View {
        let kind = seatKind(for: seat)

        let rowContent = HStack(spacing: 12) {
            Text(seatLabel(seat))
                .font(TableTypography.display(.caption, weight: .bold))
                .foregroundStyle(.white.opacity(0.60))
                .frame(width: 48, alignment: .leading)
            seatIcon(kind: kind)
            Text(seatContent(seat: seat, kind: kind))
                .foregroundStyle(kind == .empty ? AnyShapeStyle(.white.opacity(0.42)) : AnyShapeStyle(.white))
                .italic(kind == .empty)
            Spacer()
            seatBadge(kind: kind)
        }
        .padding(12)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(kind.borderColor.opacity(0.46), lineWidth: 1))

        if seat.raw == 0 {
            rowContent // Locked to the local host
        } else {
            Menu {
                Button("Bot (Empty)") { seatAssignments[seat.raw] = nil }
                if !host.connectedPlayers.isEmpty {
                    Divider()
                    Text("Connected Players")
                    ForEach(host.connectedPlayers) { player in
                        let isAssignedHere = seatAssignments[seat.raw] == player.id
                        let isElsewhere = seatAssignments.values.contains(player.id) && !isAssignedHere
                        if !isAssignedHere {
                            Button(player.displayName + (isElsewhere ? " (Move here)" : "")) {
                                for (s, pID) in seatAssignments where pID == player.id {
                                    seatAssignments[s] = nil
                                }
                                seatAssignments[seat.raw] = player.id
                            }
                        }
                    }
                }
            } label: { rowContent }
            .buttonStyle(.plain)
        }
    }

    private enum SeatKind { case host, peer, empty
        var borderColor: Color {
            switch self {
            case .host: return TableStyle.cardSelected
            case .peer: return TableStyle.cardPlayable
            case .empty: return TableStyle.passGray
            }
        }
    }

    private func seatKind(for seat: PlayerID) -> SeatKind {
        if seat.raw == 0 { return .host }
        if seatAssignments[seat.raw] != nil { return .peer }
        return .empty
    }

    private func seatContent(seat: PlayerID, kind: SeatKind) -> String {
        switch kind {
        case .host: return "You — \(playerName)"
        case .peer:
            guard let playerID = seatAssignments[seat.raw],
                  let player = host.connectedPlayers.first(where: { $0.id == playerID })
            else { return "Unknown" }
            return player.displayName
        case .empty: return "Empty — bot will fill"
        }
    }

    @ViewBuilder
    private func seatIcon(kind: SeatKind) -> some View {
        let name: String = {
            switch kind {
            case .host: return "person.fill"
            case .peer: return "person.fill.checkmark"
            case .empty: return "person.fill.questionmark"
            }
        }()
        Image(systemName: name)
            .font(TableTypography.display(.title3))
            .foregroundStyle(kind.borderColor)
            .frame(width: 40, height: 40)
            .background(Circle().fill(kind.borderColor.opacity(0.15)))
            .overlay(Circle().stroke(kind.borderColor.opacity(0.34), lineWidth: 1))
    }

    @ViewBuilder
    private func seatBadge(kind: SeatKind) -> some View {
        switch kind {
        case .host: Text("HOST").font(TableTypography.display(.caption2, weight: .bold)).foregroundStyle(TableStyle.cardSelected)
        case .peer: Text("JOINED").font(TableTypography.display(.caption2, weight: .bold)).foregroundStyle(TableStyle.cardPlayable)
        case .empty: Text("BOT").font(TableTypography.display(.caption2, weight: .bold)).foregroundStyle(TableStyle.passGray)
        }
    }

    private func seatLabel(_ p: PlayerID) -> String { ["South", "West", "North", "East"][p.raw] }

    // MARK: Start

    private var startButton: some View {
        Button { startHand() } label: {
            Label("Start hand", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue))
    }

    private func startHand() {
        BackgroundMusicPlayer.shared.stop()
        for seatRaw in [1, 2, 3] {
            let seat = PlayerID(seatRaw)
            if let playerID = seatAssignments[seatRaw],
               let player = host.connectedPlayers.first(where: { $0.id == playerID }),
               let transport = host.transport(forPlayerID: playerID) {
                let remote = RemoteSeat(seat: seat, name: player.displayName, transport: transport)
                netSession.seat(seat, asRemote: remote, name: player.displayName)
            }
        }
        bridgeToken = netSession.bindHostSession(gameSession)
        netSession.start(dealSeed: dealSeed)
        withAnimation(TableMotion.screenAnimation(reduceMotion: reduceMotion)) {
            didStartHand = true
        }
    }
}
