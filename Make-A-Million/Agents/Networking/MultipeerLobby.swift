//  MultipeerLobby.swift
//  Make-a-Million
//
//  Real cross-device transport. The headless engine plumbing (RemoteSeat,
//  NetSession, ClientSession) was written against the
//  abstract HostToClientTransport / ClientToHostTransport pair, so this
//  file's job is small in API surface even though it carries the most
//  device-edge weight:
//
//   • MultipeerHost   — advertises a table, accepts joiners, exposes one
//                       HostToClientTransport per connected peer for
//                       NetSession to wire into RemoteSeats.
//   • MultipeerClient — browses for tables, joins one, exposes a single
//                       ClientToHostTransport for ClientSession to read.
//   • MultipeerHostTransport / MultipeerClientTransport — the per-peer
//                       and per-host transport adapters themselves.
//
//  WHAT THIS FILE DOES NOT DO:
//
//   • Reconnect. If a peer drops, the underlying MCSession is closed
//     for that peer; getting them back means a fresh invite handshake
//     and a fresh transport instance. NetSession's pause-and-wait holds
//     the table; the reconnect rebind itself lands in a later slice.
//
//   • UI. There is no SwiftUI in here — the lobby screen reads
//     @Published state off MultipeerHost / MultipeerClient.
//
//  INFO.PLIST — REQUIRED, otherwise MPC silently fails to find peers:
//
//     NSBonjourServices   = [_makeamillion._tcp, _makeamillion._udp]
//     NSLocalNetworkUsageDescription = "Find nearby players."
//
//  CONCURRENCY: MCSession delegate callbacks land on a background
//  queue. We bridge into actor-isolated state via Task { @MainActor }
//  for UI-visible publishers, and via AsyncStream continuations (which
//  are thread-safe) for the transport message streams. Receive state is
//  handed into actor buffers rather than shared across awaits.
//

import Foundation
import Combine
import MultipeerConnectivity

// MARK: - Service constants

enum MultipeerConfig {
    /// MPC requires 1-15 lowercase ASCII chars + hyphens. The matching
    /// _makeamillion._tcp / _udp Bonjour services must be declared in
    /// Info.plist or iOS 14+ blocks discovery.
    static let serviceType = "makeamillion"

    /// Encryption level. `.required` is the right default — it costs
    /// little on local Wi-Fi and a family game shouldn't run in cleartext.
    static let encryption: MCEncryptionPreference = .required

    /// A stable MCPeerID for this display name, persisted across launches.
    ///
    /// `MCPeerID(displayName:)` mints a NEW underlying identity every call,
    /// even with the same name. When the identity changes between launches
    /// (e.g. after a fresh build), the other device's cached discovery and
    /// the encryption handshake can disagree, which surfaces as "connects
    /// once, then never." Apple's guidance is to archive one MCPeerID and
    /// reuse it — that's what this does.
    static func persistentPeerID(for displayName: String) -> MCPeerID {
        let key = "mpc.peerID.\(displayName)"
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let peer = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: MCPeerID.self, from: data) {
            return peer
        }
        let peer = MCPeerID(displayName: displayName)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: peer, requiringSecureCoding: true) {
            defaults.set(data, forKey: key)
        }
        return peer
    }
}

// MARK: - MultipeerHost

/// Owns the host's MCSession + advertiser. One instance per hosted table.
/// NetSession reads `connectedPeers` from the lobby UI and asks for one
/// transport per peer when it builds its RemoteSeats.
@MainActor
final class MultipeerHost: NSObject, ObservableObject {

    struct ConnectedPeer: Identifiable, Equatable {
        let id: MCPeerID
        var displayName: String { id.displayName }
    }

    @Published private(set) var connectedPeers: [ConnectedPeer] = []
    @Published private(set) var isAdvertising: Bool = false

    let localPeerID: MCPeerID
    var maxConnectedPeers: Int = Seats.count - 1

    /// All three are rebuilt together by `resetStack()`. MultipeerConnectivity
    /// retains stale per-peer state tied to the MCPeerID + session once a
    /// connection has completed, which makes the *next* handshake fail
    /// ("connects once, then never until a restart"). Swapping only the
    /// session isn't enough — the identity the framework keys on must change
    /// too — so we recreate peerID, session, and advertiser as a unit.
    private let displayName: String
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser

    /// Per-peer transport. Created when the peer connects; receives
    /// decoded ClientMessages routed by the session delegate.
    private var transports: [MCPeerID: MultipeerHostTransport] = [:]

    init(displayName: String) {
        self.displayName = displayName
        self.localPeerID = MultipeerConfig.persistentPeerID(for: displayName)
        self.session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: MultipeerConfig.encryption)
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["name": displayName],
            serviceType: MultipeerConfig.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    /// Tear the whole MPC stack down and build a fresh session + advertiser,
    /// reusing the persistent peer identity. Called when the table returns to
    /// empty, so the next joiner handshakes against a clean session. Safe
    /// only when no peers are connected — it abandons existing connections.
    private func resetStack() {
        let wasAdvertising = isAdvertising
        advertiser.stopAdvertisingPeer()
        advertiser.delegate = nil
        session.delegate = nil
        session.disconnect()
        for t in transports.values { t.markDisconnected() }
        transports.removeAll()

        session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: MultipeerConfig.encryption)
        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["name": displayName],
            serviceType: MultipeerConfig.serviceType)
        session.delegate = self
        advertiser.delegate = self
        if wasAdvertising { advertiser.startAdvertisingPeer() }
    }

    func start() {
        guard !isAdvertising else { return }
        advertiser.startAdvertisingPeer()
        isAdvertising = true
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        isAdvertising = false
        session.disconnect()
        for t in transports.values { t.markDisconnected() }
        transports.removeAll()
        connectedPeers.removeAll()
    }

    /// Hand a transport to NetSession for the given peer. Returns nil
    /// only if the peer somehow isn't connected (race on disconnect);
    /// callers should treat that as "skip this seat for this hand."
    func transport(for peer: MCPeerID) -> HostToClientTransport? {
        transports[peer]
    }
}

// MARK: MCSessionDelegate

extension MultipeerHost: MCSessionDelegate {

    nonisolated func session(_ session: MCSession,
                             peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                let t = MultipeerHostTransport(session: session, peer: peerID)
                self.transports[peerID] = t
                if !self.connectedPeers.contains(where: { $0.id == peerID }) {
                    self.connectedPeers.append(ConnectedPeer(id: peerID))
                }
            case .notConnected:
                self.transports[peerID]?.markDisconnected()
                self.transports[peerID] = nil
                self.connectedPeers.removeAll { $0.id == peerID }
                // Table is empty again — rebuild the whole stack with a
                // fresh identity so the next joiner isn't blocked by the
                // stale per-peer state MPC keeps after a completed session.
                if self.connectedPeers.isEmpty {
                    self.resetStack()
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        // Decoding is cheap and pure; do it on the delivery queue so we
        // can fail fast on a malformed message instead of polluting the
        // main actor with bad data.
        guard let msg = try? JSONDecoder().decode(ClientMessage.self, from: data)
        else { return }
        Task { @MainActor in
            self.transports[peerID]?.ingest(msg)
        }
    }

    // Streams and resources are unused; provide empty stubs to satisfy
    // the protocol without surfacing them to the rest of the code.
    nonisolated func session(_ session: MCSession,
                             didReceive stream: InputStream,
                             withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession,
                             didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             with progress: Progress) {}
    nonisolated func session(_ session: MCSession,
                             didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             at localURL: URL?,
                             withError error: Error?) {}
}

// MARK: MCNearbyServiceAdvertiserDelegate

extension MultipeerHost: MCNearbyServiceAdvertiserDelegate {

    /// Auto-accept invitations as long as there is room. Three remote
    /// seats max (seats 1, 2, 3 — seat 0 is the host themselves). For a
    /// family game, "first three to tap join get in" is the right
    /// behavior; a fancier accept/deny UI is a later concern.
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let accept = self.connectedPeers.count < self.maxConnectedPeers
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.isAdvertising = false
        }
    }
}

// MARK: - MultipeerClient

/// Owns the client's MCSession + browser. One instance per joining
/// device. ClientSession reads its transport off this once `transport`
/// becomes non-nil.
@MainActor
final class MultipeerClient: NSObject, ObservableObject {

    struct DiscoveredHost: Identifiable, Equatable {
        let id: MCPeerID
        var displayName: String { id.displayName }
    }

    enum State: Equatable {
        case idle
        case browsing
        case connecting(to: MCPeerID)
        case connected(to: MCPeerID)
        case failed(message: String)
    }

    @Published private(set) var discovered: [DiscoveredHost] = []
    @Published private(set) var state: State = .idle

    /// Available once the session reports .connected. ClientSession uses
    /// this; nil before then.
    private(set) var transport: ClientToHostTransport? = nil

    let localPeerID: MCPeerID

    /// peerID, session, and browser are rebuilt together by `resetStack()`.
    /// See MultipeerHost.resetStack for why a fresh identity (not just a
    /// fresh session) is required to connect more than once per launch.
    private let displayName: String
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser
    private var clientTransport: MultipeerClientTransport? = nil

    init(displayName: String) {
        self.displayName = displayName
        self.localPeerID = MultipeerConfig.persistentPeerID(for: displayName)
        self.session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: MultipeerConfig.encryption)
        self.browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: MultipeerConfig.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    /// Tear down and rebuild the session + browser, reusing the persistent
    /// peer identity. Run at the start of every browse cycle so each
    /// connection attempt handshakes against a clean session.
    private func resetStack() {
        browser.stopBrowsingForPeers()
        browser.delegate = nil
        session.delegate = nil
        session.disconnect()
        clientTransport?.markDisconnected()
        clientTransport = nil
        transport = nil
        discovered.removeAll()

        session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: MultipeerConfig.encryption)
        browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: MultipeerConfig.serviceType)
        session.delegate = self
        browser.delegate = self
    }

    func startBrowsing() {
        // Don't disturb a live or in-flight connection.
        if case .connected = state { return }
        if case .connecting = state { return }
        // Fresh identity for each browse cycle.
        resetStack()
        browser.startBrowsingForPeers()
        state = .browsing
    }

    func stop() {
        browser.stopBrowsingForPeers()
        session.disconnect()
        clientTransport?.markDisconnected()
        clientTransport = nil
        transport = nil
        discovered.removeAll()
        state = .idle
    }

    /// Invite a discovered host. The host's auto-accept policy decides
    /// whether the invitation succeeds; rejection surfaces as the session
    /// state going to .notConnected (which we report as .failed).
    func join(_ host: DiscoveredHost) {
        guard discovered.contains(where: { $0.id == host.id }) else { return }
        // The stack is already fresh from startBrowsing(); invite directly.
        browser.invitePeer(host.id, to: session,
                           withContext: nil, timeout: 15)
        state = .connecting(to: host.id)
    }
}

// MARK: MCSessionDelegate

extension MultipeerClient: MCSessionDelegate {

    nonisolated func session(_ session: MCSession,
                             peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                let t = MultipeerClientTransport(session: session, host: peerID)
                self.clientTransport = t
                self.transport = t
                self.state = .connected(to: peerID)
            case .notConnected:
                // Either a rejected invite or a real disconnect. Same
                // failure surface either way — the lobby UI shows the
                // message; ClientSession (if it had started) sees the
                // transport go disconnected.
                self.clientTransport?.markDisconnected()
                self.clientTransport = nil
                self.transport = nil
                if case .connecting(let p) = self.state, p == peerID {
                    self.state = .failed(message: "Host declined or unreachable")
                } else if case .connected = self.state {
                    self.state = .failed(message: "Lost connection to host")
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(HostMessage.self, from: data)
        else { return }
        Task { @MainActor in
            self.clientTransport?.ingest(msg)
        }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive stream: InputStream,
                             withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession,
                             didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             with progress: Progress) {}
    nonisolated func session(_ session: MCSession,
                             didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             at localURL: URL?,
                             withError error: Error?) {}
}

// MARK: MCNearbyServiceBrowserDelegate

extension MultipeerClient: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            if !self.discovered.contains(where: { $0.id == peerID }) {
                self.discovered.append(DiscoveredHost(id: peerID))
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discovered.removeAll { $0.id == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.state = .failed(message: "Browse failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Transports

/// Host-side per-peer transport. Held by MultipeerHost; exposed to
/// NetSession via `transport(for:)`. Delegate callbacks hand received
/// messages into actor state so the strict-concurrency rules are happy.
actor MultipeerHostTransport: HostToClientTransport {

    private nonisolated(unsafe) let session: MCSession
    private nonisolated(unsafe) let peer: MCPeerID

    private var inboundBuffer: [ClientMessage] = []
    private var waiter: CheckedContinuation<ClientMessage, Error>?
    private var connected: Bool = true

    init(session: MCSession, peer: MCPeerID) {
        self.session = session
        self.peer = peer
    }

    var isConnected: Bool { connected }

    func send(_ message: HostMessage) async throws {
        guard connected else { throw TransportError.disconnected }
        let data: Data
        do { data = try JSONEncoder().encode(message) }
        catch { throw TransportError.disconnected }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
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

    /// MultipeerHost calls this from its MCSession delegate's
    /// didReceive(_:fromPeer:) when bytes for this peer have been decoded.
    nonisolated func ingest(_ msg: ClientMessage) {
        Task { await self._ingest(msg) }
    }

    /// MultipeerHost calls this when the session reports .notConnected.
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
/// Mirror of MultipeerHostTransport.
actor MultipeerClientTransport: ClientToHostTransport {

    private nonisolated(unsafe) let session: MCSession
    private nonisolated(unsafe) let host: MCPeerID

    private var inboundBuffer: [HostMessage] = []
    private var waiter: CheckedContinuation<HostMessage, Error>?
    private var connected: Bool = true

    init(session: MCSession, host: MCPeerID) {
        self.session = session
        self.host = host
    }

    var isConnected: Bool { connected }

    func send(_ message: ClientMessage) async throws {
        guard connected else { throw TransportError.disconnected }
        let data: Data
        do { data = try JSONEncoder().encode(message) }
        catch { throw TransportError.disconnected }
        do {
            try session.send(data, toPeers: [host], with: .reliable)
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
