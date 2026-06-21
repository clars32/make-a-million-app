//
//  RemoteSeat.swift
//  Make-a-Million
//
//  One remote seat's host-side glue. Wraps a HostToClientTransport with:
//
//   • Request/response matching by UUID, so a "your turn" round trip
//     returns the right Move even if other messages cross in the gap.
//   • A long-running receive loop that consumes the wire on its own,
//     hands the matching moveResponse to whoever is awaiting it, and
//     notifies a delegate on disconnect.
//
//  WHY AN ACTOR: this object is touched concurrently by GameRunner
//  (asking for a move) and by its own receive loop (delivering a move,
//  observing a disconnect). Actor isolation makes that race-free
//  without locks. Crucially, the receive loop runs as a child Task —
//  it doesn't block the actor's other methods, but every state mutation
//  still goes through actor-isolated code.
//
//  PAUSE-AND-WAIT, SCOPE FOR THIS SLICE: if the client drops while we
//  are awaiting their move, the pending `requestMove` throws
//  `TransportError.disconnected` and the host's NetSession (the layer
//  above this) is expected to surface a pause. The reconnect path —
//  detecting that the same peer has come back, re-sending the same
//  decisionRequest — lands in the next slice along with the real MPC
//  transport. The API in this file was chosen so that adding that path
//  is local to this file and to the MPC transport, not anywhere else.
//

import Foundation

actor RemoteSeat {

    let seat: PlayerID
    private(set) var name: String
    private var transport: HostToClientTransport

    private var pendingMove: CheckedContinuation<Move, Error>?
    private var pendingRequestID: UUID?
    private var receiveTask: Task<Void, Never>?

    weak var delegate: RemoteSeatDelegate?

    init(seat: PlayerID, name: String, transport: HostToClientTransport) {
        self.seat = seat
        self.name = name
        self.transport = transport
    }

    /// Begin consuming the wire. Call once, after construction.
    func start(delegate: RemoteSeatDelegate?) {
        self.delegate = delegate
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    /// Tear down. Any pending move is failed with `.cancelled`.
    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        failPendingMove(with: TransportError.cancelled)
    }

    /// Swap in a fresh transport after the peer reconnects, and restart the
    /// receive loop on it. The previous transport is already dead and its
    /// pending request was failed at disconnect, so there is nothing to
    /// preserve here — NetSession re-issues the decision after it resumes.
    func rebind(transport: HostToClientTransport, delegate: RemoteSeatDelegate?) {
        receiveTask?.cancel()
        pendingMove = nil
        pendingRequestID = nil
        self.transport = transport
        self.delegate = delegate
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    // MARK: - High-level operations used by the host

    /// Ship a decisionRequest, await the matching moveResponse. Throws
    /// on disconnect. Exactly one outstanding request at a time per seat
    /// (the engine never asks the same seat to act twice concurrently).
    func requestMove(view: PlayerView) async throws -> Move {
        // The engine never asks one seat to act twice concurrently; if a
        // reconnect race ever re-issues a decision before the prior
        // continuation cleared, throw rather than crash the host so NetSession
        // can pause and resync.
        guard pendingMove == nil else { throw TransportError.alreadyInFlight }
        let id = UUID()
        pendingRequestID = id

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Move, Error>) in
            self.pendingMove = cont
            // Send happens off the actor so a slow transport never blocks
            // delivery of the eventual reply on the receive loop.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.send(.decisionRequest(requestID: id, view: view))
                } catch {
                    await self.failPendingMove(with: error)
                }
            }
        }
    }

    /// Push a paced observation. Best-effort — drop if the channel is
    /// gone, because the next frame or the eventual pause message will
    /// re-sync the client anyway.
    func sendObservation(_ view: PlayerView) async {
        try? await transport.send(.observation(view: view))
    }

    func sendSeatAssignment(seatNames: [String]) async {
        try? await transport.send(.seatAssignment(seat: seat, seatNames: seatNames))
    }

    func sendTableMode(isTabletop: Bool) async {
        try? await transport.send(.tableMode(isTabletop: isTabletop))
    }

    func sendHandStarted() async {
        try? await transport.send(.handStarted)
    }

    func sendHandFinished(matchScore: [Int: Int], matchWinner: Int?) async {
        try? await transport.send(
            .handFinished(matchScore: matchScore, matchWinner: matchWinner))
    }

    func sendPause(reason: PauseReason) async {
        try? await transport.send(.pauseGame(reason: reason))
    }

    func sendResume() async {
        try? await transport.send(.resumeGame)
    }

    // MARK: - Receive loop

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let msg = try await transport.receive()
                let shouldContinue = await handle(msg)
                if !shouldContinue { return }
            } catch {
                failPendingMove(with: error)
                await delegate?.remoteSeatDisconnected(self, error: error)
                return
            }
        }
    }

    private func handle(_ msg: ClientMessage) async -> Bool {
        switch msg {
        case .hello:
            // Hello is a lobby concern; once a match is running it's
            // noise (or a duplicate from a reconnect). Either way, ignore.
            return true
        case .moveResponse(let id, let move):
            // Stale or unmatched response — silently drop. The host may
            // have cancelled the round trip (pause/reset) and the client
            // didn't know yet.
            guard id == pendingRequestID, let cont = pendingMove else { return true }
            pendingMove = nil
            pendingRequestID = nil
            cont.resume(returning: move)
            return true
        case .goodbye:
            failPendingMove(with: TransportError.disconnected)
            await delegate?.remoteSeatDisconnected(self, error: TransportError.disconnected)
            return false
        }
    }

    private func failPendingMove(with error: Error) {
        guard let cont = pendingMove else { return }
        pendingMove = nil
        pendingRequestID = nil
        cont.resume(throwing: error)
    }
}

/// Notified when a RemoteSeat loses its peer. The host's NetSession
/// implements this and is responsible for pausing the table, telling the
/// other clients, and (next slice) coordinating reconnect.
protocol RemoteSeatDelegate: AnyObject, Sendable {
    func remoteSeatDisconnected(_ seat: RemoteSeat, error: Error) async
}
