//
//  HostLobbyView.swift
//  Make-a-Million
//

import SwiftUI

struct HostLobbyView: View {

    let playerName: String
    let onExit: () -> Void

    @StateObject private var multipeer: MultipeerHost
    @StateObject private var gameSession = GameSession()
    @StateObject private var netSession: NetSession

    @State private var didStartHand: Bool = false
    @State private var dealSeed: UInt64 = .random(in: .min ... .max)
    @State private var bridgeToken: AnyObject? = nil
    
    // NEW: Tabletop Toggle
    @State private var isTabletopMode: Bool = false
    @State private var seatAssignments: [Int: AnyHashable] = [:]

    /// seat → peerID for seats wired into the running hand. Unlike
    /// seatAssignments (a lobby concern that's cleared when a peer drops),
    /// this survives a disconnect, so a returning peer can be matched back
    /// to its seat and rebound for reconnect.
    @State private var liveSeatPeers: [Int: AnyHashable] = [:]

    init(playerName: String, onExit: @escaping () -> Void) {
        self.playerName = playerName
        self.onExit = onExit
        let mp = MultipeerHost(displayName: playerName)
        _multipeer = StateObject(wrappedValue: mp)
        let gs = GameSession()
        _gameSession = StateObject(wrappedValue: gs)
        
        // Initialize with default Player role, we can change it later
        _netSession = StateObject(wrappedValue: NetSession(
            hostRole: .player(seat: PlayerID(0), human: gs.human, name: playerName),
            botDifficulty: .medium))
    }

    var body: some View {
        ZStack {
            background

            if didStartHand {
                if isTabletopMode {
                    TabletopGameView(
                        netSession: netSession,
                        gameSession: gameSession,
                        onExit: {
                            netSession.stop()
                            multipeer.stop()
                            onExit()
                        })
                } else {
                    HostGameView(
                        netSession: netSession,
                        gameSession: gameSession,
                        human: gameSession.human,
                        onExit: {
                            netSession.stop()
                            multipeer.stop()
                            onExit()
                        })
                }
            } else {
                lobbyContent
            }
        }
        .onAppear {
            multipeer.maxConnectedPeers = isTabletopMode ? Seats.count : Seats.count - 1
            multipeer.start()
        }
        .onDisappear { multipeer.stop() }
        .onChange(of: multipeer.connectedPeers) { old, new in
            if didStartHand {
                // A seat's original peer reappearing — mid-hand or between
                // hands — is a reconnect. Rebind it to its seat.
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
        .onChange(of: isTabletopMode) { _, isTabletop in
            multipeer.maxConnectedPeers = isTabletop ? Seats.count : Seats.count - 1
            // Update NetSession and clear assignments when mode changes
            let newRole: NetSession.HostRole = isTabletop
                ? .tabletopSpectator
                : .player(seat: PlayerID(0), human: gameSession.human, name: playerName)
            
            netSession.setHostRole(newRole)
            seatAssignments.removeAll()
            maintainSeatAssignments()
        }
    }

    private var background: some View {
        TableFeltBackground()
    }

    private var lobbyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            
            // The Toggle!
            Picker("Host Mode", selection: $isTabletopMode) {
                Text("Play (Seat 0)").tag(false)
                Text("Tabletop Board").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)
            
            advertisingStatus
            seatList
            Spacer()
            startButton
        }
        .padding()
    }

    // MARK: Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your table")
                    .font(TableTypography.display(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text("Hosted by \(playerName)")
                    .font(.caption).foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button("Stop") {
                multipeer.stop()
                onExit()
            }
            .buttonStyle(.bordered)
            .tint(TableStyle.teamAmber)
        }
    }

    private var advertisingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(multipeer.isAdvertising ? TableStyle.cardPlayable : TableStyle.passGray)
                .frame(width: 8, height: 8)
            Text(multipeer.isAdvertising
                 ? "Visible to nearby devices — tell others to tap “Join a Table”"
                 : "Not advertising")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(12)
        .tablePanel(cornerRadius: 12, shadowOpacity: 0.14)
    }

    // MARK: Seat list & Assignments
    private func maintainSeatAssignments() {
        let connectedIDs = Set(multipeer.connectedPeers.map { AnyHashable($0.id) })
        for (seatRaw, peerID) in seatAssignments {
            if !connectedIDs.contains(peerID) { seatAssignments[seatRaw] = nil }
        }
        
        let assignedIDs = Set(seatAssignments.values)
        // If tabletop, Seat 0 is open. Otherwise, seats 1-3.
        let availableSeats = isTabletopMode ? [0, 1, 2, 3] : [1, 2, 3]
        
        for peer in multipeer.connectedPeers {
            if !assignedIDs.contains(AnyHashable(peer.id)) {
                if let emptySeat = availableSeats.first(where: { seatAssignments[$0] == nil }) {
                    seatAssignments[emptySeat] = AnyHashable(peer.id)
                }
            }
        }
    }

    private var seatList: some View {
        VStack(spacing: 8) {
            // Loop 0-3 for tabletop, or 0-3 with 0 locked for player
            ForEach(Seats.all, id: \.raw) { seat in
                seatRow(seat)
            }
        }
    }

    @ViewBuilder
    private func seatRow(_ seat: PlayerID) -> some View {
        let label = seatLabel(seat)
        let kind = seatKind(for: seat)
        
        let rowContent = HStack(spacing: 12) {
            Text(label).font(.caption).bold().foregroundStyle(.white.opacity(0.60)).frame(width: 48, alignment: .leading)
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
        
        if !isTabletopMode && seat.raw == 0 {
            rowContent // Locked to local host
        } else {
            Menu {
                Button("Bot (Empty)") { seatAssignments[seat.raw] = nil }
                if !multipeer.connectedPeers.isEmpty {
                    Divider()
                    Text("Connected Players")
                    ForEach(multipeer.connectedPeers, id: \.id) { peer in
                        let isAssignedHere = seatAssignments[seat.raw] == AnyHashable(peer.id)
                        let isElsewhere = seatAssignments.values.contains(AnyHashable(peer.id)) && !isAssignedHere
                        if !isAssignedHere {
                            Button(peer.displayName + (isElsewhere ? " (Move here)" : "")) {
                                for (s, pID) in seatAssignments { if pID == AnyHashable(peer.id) { seatAssignments[s] = nil } }
                                seatAssignments[seat.raw] = AnyHashable(peer.id)
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
            case .host: return TableStyle.cardSelected; case .peer: return TableStyle.cardPlayable; case .empty: return TableStyle.passGray
            }
        }
    }

    private func seatKind(for seat: PlayerID) -> SeatKind {
        if !isTabletopMode && seat.raw == 0 { return .host }
        if seatAssignments[seat.raw] != nil { return .peer }
        return .empty
    }

    private func seatContent(seat: PlayerID, kind: SeatKind) -> String {
        switch kind {
        case .host: return "You — \(playerName)"
        case .peer:
            guard let peerID = seatAssignments[seat.raw],
                  let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }) else { return "Unknown" }
            return peer.displayName
        case .empty: return "Empty — bot will fill"
        }
    }

    @ViewBuilder
    private func seatIcon(kind: SeatKind) -> some View {
        let name: String = {
            switch kind { case .host: return "person.fill"; case .peer: return "person.fill.checkmark"; case .empty: return "person.fill.questionmark" }
        }()
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(kind.borderColor)
            .frame(width: 40, height: 40)
            .background(Circle().fill(kind.borderColor.opacity(0.15)))
            .overlay(Circle().stroke(kind.borderColor.opacity(0.34), lineWidth: 1))
    }

    @ViewBuilder
    private func seatBadge(kind: SeatKind) -> some View {
        switch kind {
        case .host: Text("HOST").font(.caption2).bold().foregroundStyle(TableStyle.cardSelected)
        case .peer: Text("JOINED").font(.caption2).bold().foregroundStyle(TableStyle.cardPlayable)
        case .empty: Text("BOT").font(.caption2).bold().foregroundStyle(TableStyle.passGray)
        }
    }

    private func seatLabel(_ p: PlayerID) -> String { ["South", "West", "North", "East"][p.raw] }

    private var startButton: some View {
        Button { startHand() } label: {
            Text("Start hand")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule(style: .continuous).fill(TableStyle.actionBlue))
                .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func startHand() {
        let availableSeats = isTabletopMode ? [0, 1, 2, 3] : [1, 2, 3]
        
        for seatRaw in availableSeats {
            let seat = PlayerID(seatRaw)
            if let peerID = seatAssignments[seatRaw],
               let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }),
               let transport = multipeer.transport(for: peer.id) {
                let remote = RemoteSeat(seat: seat, name: peer.displayName, transport: transport)
                netSession.seat(seat, asRemote: remote, name: peer.displayName)
                liveSeatPeers[seatRaw] = peerID
            }
        }
        bridgeToken = netSession.bindHostSession(gameSession)
        netSession.start(dealSeed: dealSeed)
        didStartHand = true
    }
}
