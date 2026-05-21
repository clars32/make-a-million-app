//  ClientSession.swift
//  Make-a-Million
//
//  What runs on a NON-host device in a networked match. Counterpart to
//  GameSession (which still runs the local-only solo flow). The two are
//  intentionally shaped alike:
//
//                        GameSession            ClientSession
//      frame source      runner callback        HostMessage.observation
//      decision input    HumanAgent.pending     HostMessage.decisionRequest
//      submit            HumanAgent continuation ClientMessage.moveResponse
//      pacing            this object (queue)    this object (queue)
//      end of hand       GameRunner returns     HostMessage.handFinished
//
//  Everything else — the published table state, the pacing queue, the
//  trick-settle interleave, the snappy local preview — has the same
//  shape, so the same GameView can render either. The wiring slice will
//  put a protocol seam between them; this file is the second half of
//  the pair.
//
//  CLIENT-SIDE PACING (the design choice we made for v1): the host
//  ships observations as fast as the engine emits them. Each device
//  paces its OWN animation queue. The engine still waits at every
//  decision point, so devices that briefly drift apart re-converge on
//  every move. The win is robustness — one slow device cannot drag
//  every other player's hand to a crawl.
//
//  REDACTION GUARANTEE (unchanged): every PlayerView this object
//  receives is already a redaction the host built with view(for:).
//  This file only paces and renders — it never asks for, and never
//  has, any seat's hidden hand other than its own.
//
//  PREVIEW ON TAP: when the user plays a card we don't want to wait
//  for the host round trip before the card appears on the table. We
//  apply PlayerView.previewing(_:) locally so the card moves
//  immediately, then the host's next observation arrives shortly after
//  and reconciles. If it disagrees (it won't, but in principle) the
//  authoritative frame wins — the host is the source of truth.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ClientSession: ObservableObject {

    // MARK: - Public state for the UI

    enum Phase: Equatable {
        case connecting          // transport up, no seatAssignment yet
        case lobby               // seated, waiting for handStarted
        case running             // hand in progress
        case paused(reason: PauseReason)
        case handOver(matchWinner: Int?)
        case disconnected
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var mySeat: PlayerID? = nil
    @Published private(set) var seatNames: [String] = []

    /// The paced table state — what the UI renders right now. Continuous
    /// across the whole hand; never nil between turns, so SwiftUI's view
    /// hierarchy and matchedGeometry identities survive intact.
    @Published private(set) var displayView: PlayerView? = nil

    /// Non-nil when it's THIS device's turn to act. The UI binds tap
    /// handlers to its legalMoves.
    @Published private(set) var pending: PlayerView? = nil

    /// True when the pacing queue has caught up. Drives the
    /// "Watching play…" affordance between this player's turns.
    @Published private(set) var caughtUp: Bool = true

    // MARK: - Pacing knobs (mirror GameSession)

    private let frameInterval: Duration       = .milliseconds(500)
    private let trickSettleInterval: Duration = .milliseconds(850)
    private let settleInterval: Duration      = .milliseconds(700)
    private let maxQueuedItems = 12

    // MARK: - Wire

    private let transport: ClientToHostTransport
    private var receiveTask: Task<Void, Never>? = nil

    // MARK: - Queue state

    private enum QueueItem {
        case show(PlayerView)
        case decision(PlayerView, UUID)
        case pauseTrickSettle
        case handFinishedMarker(matchWinner: Int?)
    }
    private var queue: [QueueItem] = []
    private var drainTask: Task<Void, Never>? = nil
    private var draining = false
    private var holdPresentation = false
    private var pendingRequestID: UUID? = nil

    // MARK: - Init

    init(transport: ClientToHostTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    func start() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func stop() {
        receiveTask?.cancel()
        drainTask?.cancel()
        receiveTask = nil
        drainTask = nil
        queue.removeAll()
        holdPresentation = false
        draining = false
        pendingRequestID = nil
        pending = nil
    }

    /// Send hello with the player's chosen name. Call once after start().
    func introduce(name: String) {
        Task { [transport] in
            try? await transport.send(.hello(name: name))
        }
    }

    // MARK: - Submit (UI -> wire)

    /// Called by the UI when the user taps a legal move. Echoes the
    /// requestID from the matching decisionRequest so the host can ignore
    /// stale replies (e.g. one that arrives after a pause invalidated the
    /// round trip).
    func submit(_ move: Move) {
        guard let view = pending,
              let id = pendingRequestID,
              view.legalMoves.contains(move) else { return }

        // Snappy local preview so the card moves immediately. The host's
        // next observation will reconcile (and is authoritative if they
        // ever disagree).
        if let preview = view.previewing(move) {
            publishFrame(preview)
        }

        Task { [transport] in
            try? await transport.send(.moveResponse(requestID: id, move: move))
        }

        pending = nil
        pendingRequestID = nil
        holdPresentation = false
        startDrainIfNeeded()
    }

    // MARK: - Receive loop (wire -> queue)

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let msg = try await transport.receive()
                handle(msg)
            } catch {
                phase = .disconnected
                return
            }
        }
    }

    private func handle(_ msg: HostMessage) {
        switch msg {

        case .seatAssignment(let seat, let names):
            mySeat = seat
            seatNames = names
            if phase == .connecting { phase = .lobby }

        case .handStarted:
            phase = .running
            queue.removeAll()
            holdPresentation = false
            pendingRequestID = nil
            pending = nil
            displayView = nil
            caughtUp = true

        case .observation(let view):
            receiveFrame(view)

        case .decisionRequest(let id, let view):
            receiveDecision(view: view, id: id)

        case .handFinished(_, let winner):
            // Let the queue drain first so the deciding trick plays out;
            // when the drain reaches the marker, flip phase to handOver.
            enqueue(.handFinishedMarker(matchWinner: winner))

        case .pauseGame(let reason):
            phase = .paused(reason: reason)

        case .resumeGame:
            phase = .running
        }
    }

    // MARK: - Frame intake (mirrors GameSession.receiveFrame)

    private func receiveFrame(_ view: PlayerView) {
        if isRedundantWithDisplay(view) { return }

        if let live = effectiveTableView(),
           trickJustCompleted(comparedTo: live, incoming: view) {
            enqueueTrickSettle(from: live, resolved: view)
            return
        }
        enqueue(.show(view))
    }

    /// Trick just completed on an OBSERVATION (not a decision). Mirrors
    /// GameSession.enqueueTrickSettle: show the 4th card if we missed it,
    /// pause for visual settle, then show the cleared/resolved frame.
    private func enqueueTrickSettle(from live: PlayerView, resolved: PlayerView) {
        if live.currentTrick?.plays.count == Seats.count {
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else if let fourth = live.addingLastPlay(from: resolved) {
            enqueue(.show(fourth))
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else if let hold = trickCompletionHoldFrame(before: resolved, live: live) {
            enqueue(.show(hold))
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else {
            enqueue(.show(resolved))
        }
    }

    /// Decision arrival: enqueue as a special item so the queue still gets
    /// to play any unshown observations before we surface the decision
    /// (otherwise a fast burst of bot moves would skip past the table
    /// changes the user came here to see).
    private func receiveDecision(view: PlayerView, id: UUID) {
        if let live = effectiveTableView(),
           trickJustCompleted(comparedTo: live, incoming: view) {
            // Same shape as a trick-completing observation, but the final
            // resolved frame is the decision point.
            if live.currentTrick?.plays.count == Seats.count {
                enqueue(.pauseTrickSettle)
                enqueue(.decision(view, id))
            } else if let fourth = live.addingLastPlay(from: view) {
                enqueue(.show(fourth))
                enqueue(.pauseTrickSettle)
                enqueue(.decision(view, id))
            } else if let hold = trickCompletionHoldFrame(before: view, live: live) {
                enqueue(.show(hold))
                enqueue(.pauseTrickSettle)
                enqueue(.decision(view, id))
            } else {
                enqueue(.decision(view, id))
            }
        } else {
            enqueue(.decision(view, id))
        }
    }

    private func effectiveTableView() -> PlayerView? {
        for item in queue.reversed() {
            switch item {
            case .show(let v):       return v
            case .decision(let v, _):return v
            default: continue
            }
        }
        return displayView
    }

    private func trickJustCompleted(comparedTo live: PlayerView,
                                    incoming: PlayerView) -> Bool {
        incoming.completedTricks.count == live.completedTricks.count + 1
            && incoming.lastTrick?.plays.count == Seats.count
    }

    private func trickCompletionHoldFrame(before resolved: PlayerView,
                                          live: PlayerView) -> PlayerView? {
        guard let finished = resolved.lastTrick else { return nil }
        return PlayerView(
            me: resolved.me,
            myHand: resolved.myHand,
            phase: resolved.phase,
            toAct: resolved.toAct,
            trump: resolved.trump,
            highBid: resolved.highBid,
            highBidder: resolved.highBidder,
            passed: resolved.passed,
            opener: resolved.opener,
            bidHistory: resolved.bidHistory,
            widow: resolved.widow,
            currentTrick: Trick(leader: finished.leader, plays: finished.plays),
            completedTrickCount: live.completedTricks.count,
            completedTricks: live.completedTricks,
            matchScore: resolved.matchScore,
            legalMoves: []
        )
    }

    private func isRedundantWithDisplay(_ view: PlayerView) -> Bool {
        guard let live = displayView else { return false }
        return live.myHand.count == view.myHand.count
            && live.currentTrick?.plays.count == view.currentTrick?.plays.count
            && live.completedTricks.count == view.completedTricks.count
            && live.bidHistory.count == view.bidHistory.count
    }

    // MARK: - Queue plumbing

    private func enqueue(_ item: QueueItem) {
        queue.append(item)
        trimQueue()
        if holdPresentation { caughtUp = false; return }
        caughtUp = false
        startDrainIfNeeded()
    }

    /// Drop oldest `.show` items first if the buffer overflows. Decisions,
    /// settle pauses, and the hand-finished marker are never trimmed —
    /// dropping them would lose user-facing semantics (a turn skipped, a
    /// trick that doesn't get to settle visually, an end-of-hand never
    /// announced).
    private func trimQueue() {
        while queue.count > maxQueuedItems {
            if let idx = queue.firstIndex(where: {
                if case .show = $0 { return true }
                return false
            }) {
                queue.remove(at: idx)
            } else {
                queue.removeFirst()
            }
        }
    }

    private func publishFrame(_ view: PlayerView) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
            displayView = view
        }
    }

    private func startDrainIfNeeded() {
        guard !holdPresentation else { return }
        guard !draining else { return }
        guard !queue.isEmpty else { return }
        draining = true

        drainTask = Task { @MainActor in
            while !queue.isEmpty && !holdPresentation {
                if Task.isCancelled { return }

                switch queue.removeFirst() {

                case .show(let view):
                    publishFrame(view)
                    let nextIsSettlePause =
                        if case .pauseTrickSettle = queue.first { true } else { false }
                    if !queue.isEmpty && !nextIsSettlePause {
                        try? await Task.sleep(for: frameInterval)
                    }

                case .decision(let view, let id):
                    publishFrame(view)
                    pendingRequestID = id
                    pending = view
                    holdPresentation = true
                    // Stop draining — wait for submit() to release.
                    draining = false
                    caughtUp = queue.isEmpty
                    return

                case .pauseTrickSettle:
                    try? await Task.sleep(for: trickSettleInterval)

                case .handFinishedMarker(let winner):
                    try? await Task.sleep(for: settleInterval)
                    if Task.isCancelled { return }
                    phase = .handOver(matchWinner: winner)
                }
            }

            draining = false
            caughtUp = queue.isEmpty && !holdPresentation
            if !holdPresentation && !queue.isEmpty {
                startDrainIfNeeded()
            }
        }
    }
}
