//  InMemoryTransport.swift
//  Make-a-Million
//
//  A pair of transports that share an in-process channel. Two uses, and
//  only those two:
//
//   • Unit tests of the engine plumbing — drive a hand with a
//     RemoteAgent on one side and a scripted responder on the other,
//     with no MultipeerConnectivity in the picture.
//
//   • Local debugging of the host-side coordination logic (multi-seat
//     emission, request/response matching, eventually pause-and-wait)
//     before turning on the real radio.
//
//  Not used in production.
//
//  CONCURRENCY SHAPE — and why it isn't "just store the iterator":
//
//   AsyncStream.AsyncIterator.next() is mutating async. Storing the
//   iterator as actor-isolated state and awaiting `iterator.next()`
//   inside an actor method is rejected by Swift's strict concurrency
//   checking: the await releases actor isolation, and a second caller
//   could race a second mutation on the same iterator. There is no
//   workaround that keeps the iterator in actor state and is correct.
//
//   So we don't keep it there. Each endpoint runs one drain Task that
//   owns the iterator privately and forwards every message into actor
//   state via an isolated `deliver` call. `receive()` then pulls from
//   a tiny buffer, or suspends on a continuation that the drain wakes
//   on the next message. One drain Task per endpoint, so the "two
//   callers race the iterator" failure mode literally can't happen.
//

import Foundation

enum InMemoryTransport {

    /// Build a connected pair. The host endpoint sends HostMessages and
    /// receives ClientMessages; the client endpoint is the mirror.
    static func makePair() -> (host: HostToClientTransport,
                               client: ClientToHostTransport) {
        let hostOut = AsyncStream<HostMessage>.makeStream()
        let clientOut = AsyncStream<ClientMessage>.makeStream()

        let host = HostEndpoint(
            outbound: hostOut.continuation,
            inbound: clientOut.stream)
        let client = ClientEndpoint(
            outbound: clientOut.continuation,
            inbound: hostOut.stream)

        return (host, client)
    }

    /// Host side of an in-memory pair.
    actor HostEndpoint: HostToClientTransport {

        private let outbound: AsyncStream<HostMessage>.Continuation
        private var inboundBuffer: [ClientMessage] = []
        private var waiter: CheckedContinuation<ClientMessage, Error>?
        private var connected: Bool = true
        private var drainTask: Task<Void, Never>?

        init(outbound: AsyncStream<HostMessage>.Continuation,
             inbound: AsyncStream<ClientMessage>) {
            self.outbound = outbound
            // Drain the inbound stream from a single Task. The iterator
            // is local to this Task and never reaches actor state, which
            // is what sidesteps the strict-concurrency error.
            self.drainTask = Task { [weak self] in
                for await msg in inbound {
                    await self?.deliver(msg)
                    if Task.isCancelled { return }
                }
                await self?.streamFinished()
            }
        }

        var isConnected: Bool { connected }

        func send(_ message: HostMessage) async throws {
            guard connected else { throw TransportError.disconnected }
            outbound.yield(message)
        }

        func receive() async throws -> ClientMessage {
            if !inboundBuffer.isEmpty {
                return inboundBuffer.removeFirst()
            }
            if !connected {
                throw TransportError.disconnected
            }
            return try await withCheckedThrowingContinuation { cont in
                self.waiter = cont
            }
        }

        /// Test affordance: simulate the peer dropping. Any in-flight or
        /// future receive() throws .disconnected; outbound sends fail.
        func simulateDisconnect() {
            connected = false
            outbound.finish()
            if let cont = waiter {
                waiter = nil
                cont.resume(throwing: TransportError.disconnected)
            }
        }

        // MARK: Drain → actor handoff

        private func deliver(_ msg: ClientMessage) {
            if let cont = waiter {
                waiter = nil
                cont.resume(returning: msg)
            } else {
                inboundBuffer.append(msg)
            }
        }

        private func streamFinished() {
            connected = false
            if let cont = waiter {
                waiter = nil
                cont.resume(throwing: TransportError.disconnected)
            }
        }
    }

    /// Client side of an in-memory pair. Mirror of HostEndpoint.
    actor ClientEndpoint: ClientToHostTransport {

        private let outbound: AsyncStream<ClientMessage>.Continuation
        private var inboundBuffer: [HostMessage] = []
        private var waiter: CheckedContinuation<HostMessage, Error>?
        private var connected: Bool = true
        private var drainTask: Task<Void, Never>?

        init(outbound: AsyncStream<ClientMessage>.Continuation,
             inbound: AsyncStream<HostMessage>) {
            self.outbound = outbound
            self.drainTask = Task { [weak self] in
                for await msg in inbound {
                    await self?.deliver(msg)
                    if Task.isCancelled { return }
                }
                await self?.streamFinished()
            }
        }

        var isConnected: Bool { connected }

        func send(_ message: ClientMessage) async throws {
            guard connected else { throw TransportError.disconnected }
            outbound.yield(message)
        }

        func receive() async throws -> HostMessage {
            if !inboundBuffer.isEmpty {
                return inboundBuffer.removeFirst()
            }
            if !connected {
                throw TransportError.disconnected
            }
            return try await withCheckedThrowingContinuation { cont in
                self.waiter = cont
            }
        }

        func simulateDisconnect() {
            connected = false
            outbound.finish()
            if let cont = waiter {
                waiter = nil
                cont.resume(throwing: TransportError.disconnected)
            }
        }

        private func deliver(_ msg: HostMessage) {
            if let cont = waiter {
                waiter = nil
                cont.resume(returning: msg)
            } else {
                inboundBuffer.append(msg)
            }
        }

        private func streamFinished() {
            connected = false
            if let cont = waiter {
                waiter = nil
                cont.resume(throwing: TransportError.disconnected)
            }
        }
    }
}
