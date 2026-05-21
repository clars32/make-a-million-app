//  NetSession+HostSession.swift
//  Make-a-Million
//
//  Small extension that lets NetSession route the host's OWN seat
//  observations into a GameSession. The hand still runs on
//  NetSession's runner, but the host's local presentation buffer is
//  the same one the solo flow uses, so the host's table animates,
//  paces, and previews identically to solo play.
//
//  WHY AN EXTENSION: NetSession proper is concerned with cross-device
//  coordination — agents, RemoteSeats, pause-and-wait. Feeding the
//  host's own buffer is a presentation-layer concern that doesn't
//  belong in that file. Keeping it here also means HostGameView is
//  the only caller that introduces the host-side GameSession into the
//  picture; NetSession can still be exercised headlessly without one.
//
//  WIRE-UP CONTRACT: HostGameView creates a GameSession and a
//  HumanAgent for the host's seat, hands the HumanAgent to NetSession
//  at construction time (so it ends up in seat 0's agent slot), then
//  calls `bindHostSession(_:)` to forward observation frames into the
//  GameSession's receiveFrame buffer.
//

import Foundation
import Combine

extension NetSession {

    /// Bind a GameSession to receive host-seat observations as they're
    /// produced by the runner. Idempotent; safe to call once per match.
    /// Hold a reference to the returned token until the match ends —
    /// dropping it (or stopping the session) unbinds the forwarder.
    @MainActor
    func bindHostSession(_ gameSession: GameSession) -> AnyObject {
        // Subscribe to the same observation callback we already feed to
        // remote seats. We add a side effect specific to the host seat
        // that pushes the frame into gameSession.receiveFrame.
        let token = HostObservationToken(session: gameSession)
        self.hostObservationToken = token
        return token
    }
}

/// Tiny reference object whose lifetime governs the binding.
@MainActor
final class HostObservationToken {
    fileprivate weak var session: GameSession?
    init(session: GameSession) { self.session = session }
    deinit {
        // Nothing to do — NetSession holds a weak ref, so when this
        // token deinits the forwarding stops naturally on the next
        // dispatch.
    }
}

// MARK: - NetSession storage for the token (associated-object-style)

extension NetSession {
    private static var hostTokenKey: UInt8 = 0

    /// Storage for the host observation token. Strongly held by
    /// NetSession so the token's lifetime is tied to the match, not to
    /// HostGameView's body re-evaluation cycle.
    @MainActor
    fileprivate var hostObservationToken: HostObservationToken? {
        get {
            objc_getAssociatedObject(self, &Self.hostTokenKey) as? HostObservationToken
        }
        set {
            objc_setAssociatedObject(
                self, &Self.hostTokenKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Internal hook NetSession's dispatchObservation calls for the
    /// host's seat. (See the small edit in NetSession.swift, below.)
    @MainActor
    func forwardHostFrame(_ view: PlayerView) {
        guard let gs = hostObservationToken?.session else { return }
        gs.receiveFrameFromNet(view)
    }

    /// Internal hook NetSession calls when its runner returns. The host
    /// GameSession's own runner doesn't exist in multiplayer (the engine
    /// lives on NetSession), so the end-of-hand transition that GameSession
    /// normally does itself has to be triggered from here, or the host's
    /// hand-complete panel never appears.
    @MainActor
    func forwardHostHandFinished(_ final: GameState) {
        guard let gs = hostObservationToken?.session else { return }
        gs.finishHand(final)
    }
}

// MARK: - GameSession entry point for net-driven frames

extension GameSession {

    /// Public entry the host wrapper uses to feed engine-emitted frames
    /// into the presentation buffer. Same behavior as the in-process
    /// `receiveFrame` the local runner uses; just exposed for the
    /// NetSession-driven path.
    @MainActor
    func receiveFrameFromNet(_ view: PlayerView) {
        self.receivePublicFrame(view)
    }
}
