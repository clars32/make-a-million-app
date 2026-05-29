//  WireProtocol.swift
//  Make-a-Million
//
//  The bytes that flow between the host device and each client device.
//  Everything here is value-typed and Codable on purpose — the same
//  property that lets a Move cross the agent boundary today lets it cross
//  the network boundary tomorrow, with no engine change.
//
//  TWO INVARIANTS WORTH STARING AT:
//
//   • Only PlayerView ever travels host → client. NEVER GameState. The
//     same redaction that keeps the Monte Carlo agent honest keeps the
//     network honest: a client cannot read another seat's hand because
//     that hand is never on the wire. The host is the sole authority over
//     GameState.
//
//   • Only Move ever travels client → host. The host re-validates with
//     GameState.applying — a tampered client cannot inject an illegal
//     move because the engine still gets the final say.
//
//  These two facts together are what make "shipping moves, not state"
//  (the design note in Players.swift) real, and they are the entire
//  reason this layer is small.
//
//  WIRE COMPATIBILITY: once two devices are talking, changing these enums
//  in incompatible ways breaks live matches. ADD cases; don't reorder or
//  rename existing ones. Today the compiler enforces this because both
//  sides decode with the same Swift type; tomorrow (mixed app versions)
//  it becomes discipline.
//

import Foundation

/// Messages the host sends to one client.
nonisolated enum HostMessage: Codable, Sendable {

    /// Sent once after the client connects. Tells the client which seat
    /// they hold and the names for all four seats (so they can label the
    /// opponents in their UI).
    ///
    /// `seatNames` is indexed by seat raw value: seatNames[0] is South,
    /// seatNames[1] is West, seatNames[2] is North, seatNames[3] is East.
    case seatAssignment(seat: PlayerID, seatNames: [String])

    /// A new hand has begun. Clients should clear any leftover display
    /// state (animation queue, pending-decision view) and prepare for
    /// fresh observations.
    case handStarted

    /// One paced display frame for this client's seat. Exactly the same
    /// projection an agent receives — no hidden information. The CLIENT
    /// is responsible for pacing these frames the way GameSession paces
    /// the local human's frames today.
    case observation(view: PlayerView)

    /// It is this client's turn. The client should render its decision
    /// UI on `view` and reply with `moveResponse` carrying the SAME
    /// `requestID`. Clients must not act on an `observation` — only on
    /// a `decisionRequest`.
    case decisionRequest(requestID: UUID, view: PlayerView)

    /// The hand has settled. Carries final match score and the match
    /// winner (if the score crossed 1,000,000).
    case handFinished(matchScore: [Int: Int], matchWinner: Int?)

    /// Host has paused the table — typically because a peer disconnected.
    /// Clients should freeze any in-progress decision UI but keep the
    /// table on screen so the player knows what they were looking at.
    case pauseGame(reason: PauseReason)

    /// Host has resumed. Any in-flight decisionRequest is still live —
    /// the client has not lost its turn; it just had a longer think.
    case resumeGame
}

nonisolated enum PauseReason: Codable, Sendable, Equatable {
    case playerDisconnected(seat: PlayerID, name: String)
}

/// Messages the client sends to the host.
nonisolated enum ClientMessage: Codable, Sendable {

    /// First message after the transport connects. The host uses the
    /// name in lobby UI and to decide which seat the peer should hold.
    case hello(name: String)

    /// Reply to a `decisionRequest`. MUST echo the requestID — the host
    /// uses it to ignore stale responses (e.g. a reply that arrives
    /// after a pause has invalidated the previous round trip).
    case moveResponse(requestID: UUID, move: Move)

    /// Voluntary leave (the user tapped "Quit"). The host treats this
    /// the same as a dropped connection — both lead to pause-and-wait.
    case goodbye
}
