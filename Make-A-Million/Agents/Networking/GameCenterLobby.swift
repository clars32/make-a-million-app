//  GameCenterLobby.swift
//  Make-a-Million
//
//  Remote (internet) transport, backed by Game Center real-time matches.
//  Sibling of MultipeerLobby.swift: the headless engine plumbing
//  (RemoteSeat, NetSession, ClientSession) is written against the
//  abstract HostToClientTransport / ClientToHostTransport pair, so this
//  file only has to move bytes and surface lobby state. Apple's GKMatch
//  relay does the NAT traversal — there is no server of ours anywhere.
//
//   • GameCenterManager — process-wide singleton. Owns authentication
//                         (the GKLocalPlayer.authenticateHandler may only
//                         be set once per launch) and the invite listener,
//                         which must be alive on whatever screen the user
//                         happens to be on when an invite arrives.
//   • GameCenterHost    — owns the host side of one GKMatch. Presents the
//                         GKMatchmakerViewController invite sheet, then
//                         exposes one HostToClientTransport per connected
//                         GKPlayer for NetSession to wire into RemoteSeats.
//   • GameCenterClient  — owns the client side of a GKMatch obtained from
//                         an accepted invite. Exposes the single
//                         ClientToHostTransport that ClientSession reads.
//   • GameCenterHostTransport / GameCenterClientTransport — the per-player
//                         transport adapters (near-verbatim mirrors of the
//                         Multipeer ones; only the send call differs).
//
//  ROLE ASSIGNMENT: GKMatch has no built-in host concept — every player
//  is a peer in a full mesh. We impose roles outside the match: whoever
//  presented the invite sheet is the host; an invitee knows the host is
//  `invite.sender`. Clients filter inbound data to the host player and
//  ignore the rest of the mesh, exactly like MultipeerClient ignores
//  meshed peers.
//
//  WHAT THIS FILE DOES NOT DO:
//
//   • Reconnect. A player who leaves a GKMatch cannot rejoin it; the
//     host's existing pause-and-wait surfaces "fill seat with a bot"
//     and that is the recovery path for remote matches.
//   • Tabletop mode. That is a same-room feature; online tables always
//     seat the host as a player.
//
//  REQUIREMENTS: the com.apple.developer.game-center entitlement, and —
//  for TestFlight/App Store builds — Game Center enabled on the app
//  record in App Store Connect. Development builds work with a device
//  signed into Game Center.
//
//  CONCURRENCY: GameKit delegate callbacks land on arbitrary queues. We
//  bridge into the main actor with Task { @MainActor } for UI-visible
//  publishers, and hand received messages into actor-isolated transport
//  buffers — the same shape MultipeerLobby uses.
//

import Foundation
import Combine
import GameKit
import UIKit

// MARK: - GameCenterManager

/// Authentication + invite plumbing shared by every online screen. A
/// singleton because GameKit itself is process-global: one local player,
/// one authenticate handler, one listener registration.
@MainActor
final class GameCenterManager: NSObject, ObservableObject {

    static let shared = GameCenterManager()

    enum AuthState: Equatable {
        case unknown                  // authenticate() hasn't resolved yet
        case authenticated
        case needsSignIn              // GameKit handed us a sign-in sheet
        case failed(message: String)
    }

    /// An invite the local player accepted (from a Game Center / iMessage
    /// notification). AppRoot watches this and routes to the online
    /// client lobby. `host` is the player who sent the invite — the only
    /// peer the client transport will listen to.
    struct AcceptedInvite: Identifiable, Equatable {
        let id = UUID()
        let match: GKMatch
        let host: GKPlayer
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var authState: AuthState = .unknown
    @Published var acceptedInvite: AcceptedInvite? = nil
    @Published private(set) var inviteError: String? = nil

    /// Held until the user enters an online screen — we don't shove a
    /// Game Center sign-in sheet at someone who only wants to play solo.
    private var signInViewController: UIViewController? = nil
    private var configured = false
    private var listenerRegistered = false

    var localDisplayName: String {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : "Player"
    }

    /// Install the authenticate handler. Call once, early (AppRoot's
    /// onAppear) so invites that launch the app are not dropped. Cheap
    /// and idempotent.
    func configureAuthentication() {
        guard !configured else { return }
        configured = true
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    self.signInViewController = viewController
                    self.authState = .needsSignIn
                    return
                }
                self.signInViewController = nil
                if GKLocalPlayer.local.isAuthenticated {
                    self.authState = .authenticated
                    if !self.listenerRegistered {
                        self.listenerRegistered = true
                        GKLocalPlayer.local.register(self)
                    }
                } else {
                    self.authState = .failed(
                        message: error?.localizedDescription
                            ?? "Game Center is unavailable on this device.")
                }
            }
        }
    }

    /// Present the sign-in sheet GameKit gave us, if any. No-op when
    /// already authenticated.
    func presentSignIn() {
        guard let vc = signInViewController else { return }
        Self.topViewController()?.present(vc, animated: true)
    }

    func clearInviteError() { inviteError = nil }

    /// The view controller to present GameKit UI from: the key window's
    /// root, following the presented chain. GameKit's controllers are
    /// UIKit-only, so SwiftUI screens present them this way.
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: GKLocalPlayerListener

extension GameCenterManager: GKLocalPlayerListener {

    /// The local player accepted an invite (usually via the system
    /// notification). Resolve it into a live GKMatch and publish; AppRoot
    /// routes the user into the online client lobby.
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in
            do {
                let match = try await GKMatchmaker.shared().match(for: invite)
                self.acceptedInvite = AcceptedInvite(match: match, host: invite.sender)
                self.inviteError = nil
            } catch {
                self.inviteError = error.localizedDescription
            }
        }
    }
}

// MARK: - GameCenterHost

/// Owns the host's GKMatch. One instance per hosted online table. The
/// lobby UI reads `connectedPlayers` and asks for one transport per
/// player when it builds its RemoteSeats — the same contract
/// MultipeerHost offers the local lobby.
@MainActor
final class GameCenterHost: NSObject, ObservableObject {

    struct ConnectedPlayer: Identifiable, Equatable {
        let id: String            // GKPlayer.gamePlayerID
        let displayName: String
    }

    @Published private(set) var connectedPlayers: [ConnectedPlayer] = []
    @Published private(set) var hasMatch: Bool = false
    @Published private(set) var lastError: String? = nil

    private var match: GKMatch? = nil
    private var players: [String: GKPlayer] = [:]
    private var transports: [String: GameCenterHostTransport] = [:]

    /// Present the Game Center invite sheet. First call creates the
    /// match; later calls (with a live match) add players to it, so the
    /// host can top the table up before dealing.
    func presentInviteSheet() {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = Seats.count        // host + up to 3 remote seats
        request.inviteMessage = "Join my Make-a-Million table!"

        guard let vc = GKMatchmakerViewController(matchRequest: request) else {
            lastError = "Couldn't open the Game Center invite screen."
            return
        }
        vc.matchmakerDelegate = self
        vc.matchmakingMode = .inviteOnly
        if let match { vc.addPlayers(to: match) }
        GameCenterManager.topViewController()?.present(vc, animated: true)
    }

    /// Hand a transport to the lobby for the given player. nil only if
    /// the player dropped in a race; callers treat that as "seat stays
    /// a bot for this hand."
    func transport(forPlayerID id: String) -> HostToClientTransport? {
        transports[id]
    }

    /// Tear the table down. Disconnects every peer — a GKMatch cannot be
    /// rejoined, so this is only called when the host abandons the table.
    func stop() {
        match?.delegate = nil
        match?.disconnect()
        match = nil
        for t in transports.values { t.markDisconnected() }
        transports.removeAll()
        players.removeAll()
        connectedPlayers.removeAll()
        hasMatch = false
    }

    private func adopt(match newMatch: GKMatch) {
        if let old = match, old !== newMatch {
            old.delegate = nil
            old.disconnect()
        }
        match = newMatch
        newMatch.delegate = self
        hasMatch = true
        // Players who connected while the matchmaker sheet was up are
        // already in the match's player list — fold them in now.
        for player in newMatch.players { add(player: player) }
    }

    private func add(player: GKPlayer) {
        guard let match else { return }
        let id = player.gamePlayerID
        guard transports[id] == nil else { return }
        players[id] = player
        transports[id] = GameCenterHostTransport(match: match, player: player)
        if !connectedPlayers.contains(where: { $0.id == id }) {
            connectedPlayers.append(
                ConnectedPlayer(id: id, displayName: player.displayName))
        }
    }

    private func remove(playerID id: String) {
        transports[id]?.markDisconnected()
        transports[id] = nil
        players[id] = nil
        connectedPlayers.removeAll { $0.id == id }
    }
}

// MARK: GKMatchDelegate (host)

extension GameCenterHost: GKMatchDelegate {

    nonisolated func match(_ match: GKMatch,
                           player: GKPlayer,
                           didChange state: GKPlayerConnectionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.add(player: player)
            case .disconnected:
                self.remove(playerID: player.gamePlayerID)
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func match(_ match: GKMatch,
                           didReceive data: Data,
                           fromRemotePlayer player: GKPlayer) {
        // Decode on the delivery queue (cheap, pure) so malformed bytes
        // die here instead of reaching the main actor.
        guard let msg = try? JSONDecoder().decode(ClientMessage.self, from: data)
        else { return }
        Task { @MainActor in
            self.transports[player.gamePlayerID]?.ingest(msg)
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription ?? "The match failed."
            for t in self.transports.values { t.markDisconnected() }
        }
    }
}

// MARK: GKMatchmakerViewControllerDelegate

extension GameCenterHost: GKMatchmakerViewControllerDelegate {

    nonisolated func matchmakerViewControllerWasCancelled(
        _ viewController: GKMatchmakerViewController) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
        }
    }

    nonisolated func matchmakerViewController(
        _ viewController: GKMatchmakerViewController,
        didFailWithError error: Error) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.lastError = error.localizedDescription
        }
    }

    nonisolated func matchmakerViewController(
        _ viewController: GKMatchmakerViewController,
        didFind match: GKMatch) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.adopt(match: match)
        }
    }
}

// MARK: - GameCenterClient

/// Owns the client side of a GKMatch reached through an accepted invite.
/// One instance per joined table. ClientSession reads `transport` once
/// `state` reports connected.
@MainActor
final class GameCenterClient: NSObject, ObservableObject {

    enum State: Equatable {
        case connecting
        case connected
        case failed(message: String)
    }

    @Published private(set) var state: State = .connecting

    private(set) var transport: ClientToHostTransport? = nil
    let hostName: String

    private let match: GKMatch
    private let hostID: String
    private var clientTransport: GameCenterClientTransport? = nil

    init(match: GKMatch, host: GKPlayer) {
        self.match = match
        self.hostID = host.gamePlayerID
        self.hostName = host.displayName
        super.init()
        match.delegate = self
        let t = GameCenterClientTransport(match: match, host: host)
        self.clientTransport = t
        self.transport = t
        // The host created the match before inviting us, so it is often
        // already in the player list by the time we adopt the match.
        if match.players.contains(where: { $0.gamePlayerID == hostID }) {
            state = .connected
        }
    }

    func stop() {
        match.delegate = nil
        match.disconnect()
        clientTransport?.markDisconnected()
        clientTransport = nil
        transport = nil
    }
}

// MARK: GKMatchDelegate (client)

extension GameCenterClient: GKMatchDelegate {

    nonisolated func match(_ match: GKMatch,
                           player: GKPlayer,
                           didChange state: GKPlayerConnectionState) {
        Task { @MainActor in
            // Only the host drives our connection state; other clients in
            // the mesh coming and going is the host's business, not ours.
            guard player.gamePlayerID == self.hostID else { return }
            switch state {
            case .connected:
                self.state = .connected
            case .disconnected:
                self.clientTransport?.markDisconnected()
                self.state = .failed(message: "Lost connection to the host")
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func match(_ match: GKMatch,
                           didReceive data: Data,
                           fromRemotePlayer player: GKPlayer) {
        guard let msg = try? JSONDecoder().decode(HostMessage.self, from: data)
        else { return }
        Task { @MainActor in
            // Only accept data from the host, never from a meshed client.
            guard player.gamePlayerID == self.hostID else { return }
            self.clientTransport?.ingest(msg)
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in
            self.clientTransport?.markDisconnected()
            self.state = .failed(
                message: error?.localizedDescription ?? "The connection failed.")
        }
    }
}

// MARK: - Transports

/// Host-side per-player transport. Held by GameCenterHost; exposed to the
/// lobby via `transport(forPlayerID:)`. Same buffer/waiter shape as
/// MultipeerHostTransport — only the send call differs.
actor GameCenterHostTransport: HostToClientTransport {

    private nonisolated(unsafe) let match: GKMatch
    private nonisolated(unsafe) let player: GKPlayer

    private var inboundBuffer: [ClientMessage] = []
    private var waiter: CheckedContinuation<ClientMessage, Error>?
    private var connected: Bool = true

    init(match: GKMatch, player: GKPlayer) {
        self.match = match
        self.player = player
    }

    var isConnected: Bool { connected }

    func send(_ message: HostMessage) async throws {
        guard connected else { throw TransportError.disconnected }
        let data: Data
        do { data = try JSONEncoder().encode(message) }
        catch { throw TransportError.disconnected }
        do {
            try match.send(data, to: [player], dataMode: .reliable)
        } catch {
            throw TransportError.disconnected
        }
    }

    func receive() async throws -> ClientMessage {
        if !inboundBuffer.isEmpty { return inboundBuffer.removeFirst() }
        if !connected { throw TransportError.disconnected }
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    /// GameCenterHost calls this from its match delegate when bytes for
    /// this player have been decoded.
    nonisolated func ingest(_ msg: ClientMessage) {
        Task { await self._ingest(msg) }
    }

    /// GameCenterHost calls this when the player leaves the match.
    nonisolated func markDisconnected() {
        Task { await self._markDisconnected() }
    }

    private func _ingest(_ msg: ClientMessage) {
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: msg)
        } else {
            inboundBuffer.append(msg)
        }
    }

    private func _markDisconnected() {
        connected = false
        if let cont = waiter {
            waiter = nil
            cont.resume(throwing: TransportError.disconnected)
        }
    }
}

/// Client-side single transport (the client only ever talks to the host).
/// Mirror of GameCenterHostTransport.
actor GameCenterClientTransport: ClientToHostTransport {

    private nonisolated(unsafe) let match: GKMatch
    private nonisolated(unsafe) let host: GKPlayer

    private var inboundBuffer: [HostMessage] = []
    private var waiter: CheckedContinuation<HostMessage, Error>?
    private var connected: Bool = true

    init(match: GKMatch, host: GKPlayer) {
        self.match = match
        self.host = host
    }

    var isConnected: Bool { connected }

    func send(_ message: ClientMessage) async throws {
        guard connected else { throw TransportError.disconnected }
        let data: Data
        do { data = try JSONEncoder().encode(message) }
        catch { throw TransportError.disconnected }
        do {
            try match.send(data, to: [host], dataMode: .reliable)
        } catch {
            throw TransportError.disconnected
        }
    }

    func receive() async throws -> HostMessage {
        if !inboundBuffer.isEmpty { return inboundBuffer.removeFirst() }
        if !connected { throw TransportError.disconnected }
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    nonisolated func ingest(_ msg: HostMessage) {
        Task { await self._ingest(msg) }
    }

    nonisolated func markDisconnected() {
        Task { await self._markDisconnected() }
    }

    private func _ingest(_ msg: HostMessage) {
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: msg)
        } else {
            inboundBuffer.append(msg)
        }
    }

    private func _markDisconnected() {
        connected = false
        if let cont = waiter {
            waiter = nil
            cont.resume(throwing: TransportError.disconnected)
        }
    }
}
