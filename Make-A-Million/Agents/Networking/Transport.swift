//
//  Transport.swift
//  Make-a-Million
//
//  Abstract channel between host and ONE client. The host holds one of
//  these per remote seat; the client holds exactly one (its connection
//  to the host). Implementations:
//
//   • MultipeerTransport — real cross-device transport over
//     MultipeerConnectivity (next slice).
//   • InMemoryTransport  — two paired endpoints in one process. Used for
//     tests and for headless verification that the engine plumbing is
//     right before turning on the radio.
//
//  The protocol is deliberately tiny. Anything richer — request/response
//  matching, reconnect, pause/resume — lives one layer up, in RemoteSeat
//  and the host's NetSession. A new transport only has to do "send these
//  bytes, receive those bytes, and tell me when you're gone."
//
//  Symmetric pair: HostToClientTransport is what the host uses;
//  ClientToHostTransport is what the client uses. The directions are
//  inverted (the host sends HostMessage, receives ClientMessage; the
//  client sends ClientMessage, receives HostMessage). Splitting them by
//  type means a host implementation cannot accidentally send a
//  ClientMessage — the compiler refuses.
//

import Foundation

/// Host-side endpoint: sends HostMessages, receives ClientMessages.
protocol HostToClientTransport: AnyObject, Sendable {

    /// True when bytes can flow right now. Goes false on disconnect and
    /// only goes true again after a (future) reconnect completes.
    var isConnected: Bool { get async }

    /// Push one host → client message. Throws if the channel is gone.
    func send(_ message: HostMessage) async throws

    /// Suspend until the next client → host message arrives. Throws on
    /// disconnect — the caller decides between pause-and-wait and giving
    /// up on the seat.
    func receive() async throws -> ClientMessage
}

/// Mirror role used by a client device. The client only ever sends
/// ClientMessages and only ever receives HostMessages.
protocol ClientToHostTransport: AnyObject, Sendable {

    var isConnected: Bool { get async }

    func send(_ message: ClientMessage) async throws
    func receive() async throws -> HostMessage
}

enum TransportError: Error, Equatable {
    case disconnected
    case cancelled
}
