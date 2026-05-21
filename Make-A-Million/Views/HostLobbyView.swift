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
    
    // NEW: Interactive Tracking for Seat Map
    @State private var seatAssignments: [Int: AnyHashable] = [:]

    init(playerName: String, onExit: @escaping () -> Void) {
        self.playerName = playerName
        self.onExit = onExit
        let mp = MultipeerHost(displayName: playerName)
        _multipeer = StateObject(wrappedValue: mp)
        let gs = GameSession()
        _gameSession = StateObject(wrappedValue: gs)
        _netSession = StateObject(wrappedValue: NetSession(
            hostSeat: PlayerID(0),
            hostName: playerName,
            hostHuman: gs.human,
            botDifficulty: .medium))
    }

    var body: some View {
        ZStack {
            background

            if didStartHand {
                HostGameView(
                    netSession: netSession,
                    gameSession: gameSession,
                    human: gameSession.human,
                    onExit: {
                        netSession.stop()
                        multipeer.stop()
                        onExit()
                    })
            } else {
                lobbyContent
            }
        }
        .onAppear { multipeer.start() }
        .onDisappear { multipeer.stop() }
        .onChange(of: multipeer.connectedPeers.count) { _, _ in
            maintainSeatAssignments()
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.green.opacity(0.18), Color.teal.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var lobbyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
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
                Text("Your table").font(.system(.title2, design: .rounded)).bold()
                Text("Hosted by \(playerName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") {
                multipeer.stop()
                onExit()
            }
            .buttonStyle(.bordered)
        }
    }

    private var advertisingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(multipeer.isAdvertising ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(multipeer.isAdvertising
                 ? "Visible to nearby devices — tell others to tap “Join a Table”"
                 : "Not advertising")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Seat list & Assignments

    private func maintainSeatAssignments() {
        let connectedIDs = Set(multipeer.connectedPeers.map { AnyHashable($0.id) })
        
        // Remove disconnected peers from seats
        for (seatRaw, peerID) in seatAssignments {
            if !connectedIDs.contains(peerID) {
                seatAssignments[seatRaw] = nil
            }
        }
        
        // Auto-assign new peers to the first available empty seat
        let assignedIDs = Set(seatAssignments.values)
        for peer in multipeer.connectedPeers {
            if !assignedIDs.contains(AnyHashable(peer.id)) {
                if let emptySeat = [1, 2, 3].first(where: { seatAssignments[$0] == nil }) {
                    seatAssignments[emptySeat] = AnyHashable(peer.id)
                }
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
        let label = seatLabel(seat)
        let kind = seatKind(for: seat)
        
        let rowContent = HStack(spacing: 12) {
            Text(label)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            seatIcon(kind: kind)
            Text(seatContent(seat: seat, kind: kind))
                .foregroundStyle(kind == .empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .italic(kind == .empty)
            Spacer()
            seatBadge(kind: kind)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(kind.borderColor.opacity(0.4), lineWidth: 1))
        
        if seat.raw == 0 {
            rowContent // Host seat cannot be interacted with
        } else {
            // Non-host seats become menus to swap connected players
            Menu {
                Button("Bot (Empty)") {
                    seatAssignments[seat.raw] = nil
                }
                
                if !multipeer.connectedPeers.isEmpty {
                    Divider()
                    Text("Connected Players")
                    ForEach(multipeer.connectedPeers, id: \.id) { peer in
                        let isAssignedHere = seatAssignments[seat.raw] == AnyHashable(peer.id)
                        let isAssignedElsewhere = seatAssignments.values.contains(AnyHashable(peer.id)) && !isAssignedHere
                        
                        if !isAssignedHere {
                            Button(peer.displayName + (isAssignedElsewhere ? " (Move here)" : "")) {
                                // If player is moved, empty their old seat
                                for (s, pID) in seatAssignments {
                                    if pID == AnyHashable(peer.id) { seatAssignments[s] = nil }
                                }
                                seatAssignments[seat.raw] = AnyHashable(peer.id)
                            }
                        }
                    }
                }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        }
    }

    private enum SeatKind { case host, peer, empty
        var borderColor: Color {
            switch self {
            case .host: return .blue
            case .peer: return .green
            case .empty: return .gray
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
            guard let peerID = seatAssignments[seat.raw],
                  let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }) else {
                return "Unknown"
            }
            return peer.displayName
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
            .font(.title3)
            .foregroundStyle(kind.borderColor)
            .frame(width: 40, height: 40)
            .background(Circle().fill(kind.borderColor.opacity(0.15)))
    }

    @ViewBuilder
    private func seatBadge(kind: SeatKind) -> some View {
        switch kind {
        case .host:
            Text("HOST").font(.caption2).bold().foregroundStyle(.blue)
        case .peer:
            Text("JOINED").font(.caption2).bold().foregroundStyle(.green)
        case .empty:
            Text("BOT").font(.caption2).bold().foregroundStyle(.gray)
        }
    }

    private func seatLabel(_ p: PlayerID) -> String {
        ["South", "West", "North", "East"][p.raw]
    }

    // MARK: Start

    private var startButton: some View {
        Button {
            startHand()
        } label: {
            Text("Start hand")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
    }

    private func startHand() {
        for seatRaw in 1...3 {
            let seat = PlayerID(seatRaw)
            
            // Look up the explicit map we created from the UI interactions
            if let peerID = seatAssignments[seatRaw],
               let peer = multipeer.connectedPeers.first(where: { AnyHashable($0.id) == peerID }),
               let transport = multipeer.transport(for: peer.id) {
                
                let remote = RemoteSeat(seat: seat, name: peer.displayName, transport: transport)
                netSession.seat(seat, asRemote: remote, name: peer.displayName)
            }
        }
        bridgeToken = netSession.bindHostSession(gameSession)
        netSession.start(dealSeed: dealSeed)
        didStartHand = true
    }

}
