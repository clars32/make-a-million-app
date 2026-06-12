//
//  HostLobbyView.swift
//  Make-a-Million
//

import SwiftUI

struct HostLobbyView: View {
    let playerName: String
    let onExit: () -> Void

    var body: some View {
        HostLobbyCore(
            playerName: playerName,
            mode: .local,
            onExit: onExit)
    }
}

struct TabletopHostLobbyView: View {
    let playerName: String
    let onExit: () -> Void

    var body: some View {
        HostLobbyCore(
            playerName: playerName,
            mode: .tabletop,
            onExit: onExit)
    }
}

private struct HostLobbyCore: View {

    enum Mode {
        case local
        case tabletop

        var isTabletop: Bool {
            if case .tabletop = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .local: return "Local table"
            case .tabletop: return "Tabletop board"
            }
        }

        var subtitle: String {
            switch self {
            case .local: return "Hosted by"
            case .tabletop: return "Shared board hosted by"
            }
        }

        var advertisingHint: String {
            switch self {
            case .local:
                return "Visible to nearby devices - tell others to tap Join Local"
            case .tabletop:
                return "Visible to nearby devices - players should tap Join Local"
            }
        }

        var startTitle: String {
            switch self {
            case .local: return "Start hand"
            case .tabletop: return "Start tabletop"
            }
        }

        var maxConnectedPeers: Int {
            switch self {
            case .local: return Seats.count - 1
            case .tabletop: return Seats.count
            }
        }
    }

    let playerName: String
    let mode: Mode
    let onExit: () -> Void

    @StateObject private var multipeer: MultipeerHost
    @StateObject private var gameSession = GameSession()
    @StateObject private var netSession: NetSession

    @State private var didStartHand: Bool = false
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)
    @State private var showingSettings = false
    @State private var bridgeToken: AnyObject? = nil
    @State private var hostSeat: PlayerID?
    @State private var seatAssignments: [Int: AnyHashable] = [:]

    /// seat -> peerID for seats wired into the running hand. Unlike
    /// seatAssignments (a lobby concern that's cleared when a peer drops),
    /// this survives a disconnect, so a returning peer can be matched back
    /// to its seat and rebound for reconnect.
    @State private var liveSeatPeers: [Int: AnyHashable] = [:]

    init(playerName: String, mode: Mode, onExit: @escaping () -> Void) {
        self.playerName = playerName
        self.mode = mode
        self.onExit = onExit
        _hostSeat = State(initialValue: mode.isTabletop ? nil : PlayerID(0))

        let mp = MultipeerHost(displayName: playerName)
        _multipeer = StateObject(wrappedValue: mp)

        let gs = GameSession()
        _gameSession = StateObject(wrappedValue: gs)

        let hostRole: NetSession.HostRole = mode.isTabletop
            ? .tabletopSpectator
            : .player(seat: PlayerID(0), human: gs.human, name: playerName)
        _netSession = StateObject(wrappedValue: NetSession(
            hostRole: hostRole,
            botDifficulty: GameSettings.shared.botDifficulty))
    }

    var body: some View {
        ZStack {
            background

            if didStartHand {
                if mode.isTabletop {
                    TabletopGameView(
                        netSession: netSession,
                        gameSession: gameSession,
                        onExit: stopAndExit)
                } else {
                    HostGameView(
                        netSession: netSession,
                        gameSession: gameSession,
                        human: gameSession.human,
                        onExit: stopAndExit)
                }
            } else {
                lobbyContent
            }
        }
        .onAppear {
            if !didStartHand {
                BackgroundMusicPlayer.shared.setGameActive(false)
                BackgroundMusicPlayer.shared.playLobbyMusic()
            }
            multipeer.maxConnectedPeers = mode.maxConnectedPeers
            configureHostRole()
            multipeer.start()
            maintainSeatAssignments()
        }
        .onDisappear { multipeer.stop() }
        .onChange(of: multipeer.connectedPeers) { old, new in
            if didStartHand {
                let oldIDs = Set(old.map { AnyHashable($0.id) })
                for peer in new where !oldIDs.contains(AnyHashable(peer.id)) {
                    if let seatRaw = liveSeatPeers.first(
                        where: { $0.value == AnyHashable(peer.id) })?.key,
                       let transport = multipeer.transport(for: peer.id) {
                        netSession.reconnect(
                            seat: PlayerID(seatRaw), transport: transport)
                    }
                }
            } else {
                maintainSeatAssignments()
            }
        }
    }

    private var background: some View {
        TableFeltBackground()
    }

    private var lobbyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modeSummary
            advertisingStatus
            seatList
            Spacer()
            startButton
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(mode.subtitle) \(playerName)")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.bordered)
            .tint(TableStyle.cardSelected)
            .accessibilityLabel("Settings")
            Button("Stop") {
                multipeer.stop()
                onExit()
            }
            .buttonStyle(.bordered)
            .tint(TableStyle.teamAmber)
        }
        .sheet(isPresented: $showingSettings) {
            // Pre-match: rules are editable here and apply to the first deal.
            SettingsView(settings: .shared, rulesLocked: false) {
                showingSettings = false
            }
        }
    }

    private var modeSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: mode.isTabletop ? "rectangle.on.rectangle.angled" : "person.crop.circle.badge.checkmark")
                .font(TableTypography.display(.title3))
                .foregroundStyle(mode.isTabletop ? TableStyle.tableGold : TableStyle.cardSelected)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.isTabletop ? "Board-only host" : "You can choose your seat")
                    .font(TableTypography.display(.headline, weight: .bold))
                    .foregroundStyle(.white)
                Text(mode.isTabletop
                    ? "All four seats can be nearby players or bots."
                    : "Tap any seat row to move yourself or assign connected players.")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
        }
        .padding(12)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
    }

    private var advertisingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(multipeer.isAdvertising ? TableStyle.cardPlayable : TableStyle.passGray)
                .frame(width: 8, height: 8)
            Text(multipeer.isAdvertising ? mode.advertisingHint : "Not advertising")
                .font(TableTypography.display(.caption))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(12)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
    }

    // MARK: Seat list & assignments

    private func configureHostRole() {
        if let hostSeat {
            netSession.setHostRole(.player(seat: hostSeat, human: gameSession.human, name: playerName))
        } else {
            netSession.setHostRole(.tabletopSpectator)
        }
    }

    private func maintainSeatAssignments() {
        let connectedIDs = Set(multipeer.connectedPeers.map { AnyHashable($0.id) })
        for (seatRaw, peerID) in seatAssignments {
            if !connectedIDs.contains(peerID) { seatAssignments[seatRaw] = nil }
        }

        if let hostSeat {
            seatAssignments[hostSeat.raw] = nil
        }

        var assignedIDs = Set(seatAssignments.values)
        for peer in multipeer.connectedPeers {
            let peerID = AnyHashable(peer.id)
            if !assignedIDs.contains(peerID),
               let emptySeat = assignableSeats.first(where: { seatAssignments[$0.raw] == nil }) {
                seatAssignments[emptySeat.raw] = peerID
                assignedIDs.insert(peerID)
            }
        }
    }

    private var assignableSeats: [PlayerID] {
        Seats.all.filter { seat in
            guard let hostSeat else { return true }
            return seat != hostSeat
        }
    }

    private var seatList: some View {
        VStack(spacing: 8) {
            ForEach(Seats.all, id: \.raw) { seat in
                seatRow(seat)
            }
        }
    }

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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(kind.borderColor.opacity(0.46), lineWidth: 1))

        return Menu {
            seatMenuContent(for: seat, kind: kind)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func seatMenuContent(for seat: PlayerID, kind: SeatKind) -> some View {
        if !mode.isTabletop {
            if hostSeat == seat {
                Text("You are sitting here")
            } else {
                Button("Sit here") {
                    moveHost(to: seat)
                }
            }
        }

        if hostSeat != seat {
            Button("Bot (Empty)") {
                seatAssignments[seat.raw] = nil
                maintainSeatAssignments()
            }

            if !multipeer.connectedPeers.isEmpty {
                Divider()
                Text("Connected Players")
                ForEach(multipeer.connectedPeers, id: \.id) { peer in
                    let peerID = AnyHashable(peer.id)
                    let isAssignedHere = seatAssignments[seat.raw] == peerID
                    let isElsewhere = seatAssignments.values.contains(peerID) && !isAssignedHere
                    if !isAssignedHere {
                        Button(peer.displayName + (isElsewhere ? " (Move here)" : "")) {
                            assign(peer: peer, to: seat)
                        }
                    }
                }
            }
        }
    }

    private enum SeatKind {
        case host
        case peer
        case empty

        var borderColor: Color {
            switch self {
            case .host: return TableStyle.cardSelected
            case .peer: return TableStyle.cardPlayable
            case .empty: return TableStyle.passGray
            }
        }
    }

    private func seatKind(for seat: PlayerID) -> SeatKind {
        if hostSeat == seat { return .host }
        if seatAssignments[seat.raw] != nil { return .peer }
        return .empty
    }

    private func seatContent(seat: PlayerID, kind: SeatKind) -> String {
        switch kind {
        case .host:
            return "You - \(playerName)"
        case .peer:
            guard let peerID = seatAssignments[seat.raw],
                  let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }) else {
                return "Unknown"
            }
            return peer.displayName
        case .empty:
            return "Empty - bot will fill"
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
        case .host:
            Text("HOST")
                .font(TableTypography.display(.caption2, weight: .bold))
                .foregroundStyle(TableStyle.cardSelected)
        case .peer:
            Text("JOINED")
                .font(TableTypography.display(.caption2, weight: .bold))
                .foregroundStyle(TableStyle.cardPlayable)
        case .empty:
            Text("BOT")
                .font(TableTypography.display(.caption2, weight: .bold))
                .foregroundStyle(TableStyle.passGray)
        }
    }

    private func seatLabel(_ p: PlayerID) -> String {
        ["South", "West", "North", "East"][p.raw]
    }

    private func moveHost(to seat: PlayerID) {
        guard hostSeat != seat else { return }
        seatAssignments[seat.raw] = nil
        hostSeat = seat
        configureHostRole()
        maintainSeatAssignments()
    }

    private func assign(peer: MultipeerHost.ConnectedPeer, to seat: PlayerID) {
        let peerID = AnyHashable(peer.id)
        for (seatRaw, assignedPeerID) in seatAssignments where assignedPeerID == peerID {
            seatAssignments[seatRaw] = nil
        }
        seatAssignments[seat.raw] = peerID
        maintainSeatAssignments()
    }

    private var startButton: some View {
        Button { startHand() } label: {
            Text(mode.startTitle)
                .font(TableTypography.display(.headline, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule(style: .continuous).fill(TableStyle.actionBlue))
                .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func startHand() {
        BackgroundMusicPlayer.shared.stop()
        configureHostRole()

        for seat in assignableSeats {
            if let peerID = seatAssignments[seat.raw],
               let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }),
               let transport = multipeer.transport(for: peer.id) {
                let remote = RemoteSeat(seat: seat, name: peer.displayName, transport: transport)
                netSession.seat(seat, asRemote: remote, name: peer.displayName)
                liveSeatPeers[seat.raw] = peerID
            }
        }

        bridgeToken = netSession.bindHostSession(gameSession)
        netSession.start(dealSeed: dealSeed)
        didStartHand = true
    }

    private func stopAndExit() {
        netSession.stop()
        multipeer.stop()
        onExit()
    }
}
