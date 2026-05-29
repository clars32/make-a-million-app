//  NetSession.swift
//  Make-a-Million
//
//  The host's networked counterpart to GameSession. Owns the runner, the
//  agents (one HumanAgent for the host, one pause-aware remote agent per
//  connected remote player, MonteCarloAgents in any empty seat), and the per-seat
//  RemoteSeat channels. Drives the same GameRunner that single-device
//  play uses — the engine is unchanged.
//
//  WHAT THIS FILE OWNS, AND WHAT IT DOESN'T:
//
//   • OWNS  — seat assignment, RemoteSeat lifecycle, the agent array
//             the runner is built with, dispatching observation frames
//             to remote seats, pause-and-wait on disconnect, exposing
//             a published presentation state for the host's GameView.
//
//   • DOES NOT OWN — the host's own animation pacing. The host is one
//             of the players and still uses GameSession's local buffer
//             for its own seat. (See "host's local seat" below.) This
//             file deals exclusively with the cross-device coordination.
//
//   • DOES NOT OWN — any rule. As always, every transition still goes
//             through GameState.applying. NetSession only chooses WHO
//             gets asked for a move and routes the answer.
//
//  CLIENT-SIDE PACING, RESTATED: this file fires observations as fast
//  as the engine produces them. Each client (and the host's own
//  GameSession for the host's seat) runs its own animation queue. The
//  engine still waits for the acting player at every decision point, so
//  any drift between devices re-converges on every move. The win is
//  robustness — one sluggish device can't drag the whole table.
//
//  PAUSE-AND-WAIT, V1: if a remote seat drops, NetSession pauses by
//  freezing the runner-side request. Today that means: any in-flight
//  decisionRequest to the dropped seat throws .disconnected from
//  RemoteSeat, NetSession catches it, broadcasts a pauseGame to every
//  OTHER seat, and SUSPENDS until the user resolves the situation.
//  Resolution is one of:
//
//    (a) the same peer reconnects — handled by the next slice along
//        with the MPC transport; the suspended request is re-issued
//        with a fresh requestID over the new channel.
//    (b) the host taps "fill with bot" — NetSession swaps a freshly
//        seeded MonteCarloAgent into that seat and resumes.
//
//  The hook for (b) is in place (resumeWithBot); (a) is wired through
//  the same continuation but is exercised by the future MPC layer.
//
//  WHY @MainActor: SwiftUI observes `phase` and `seatStatus`. Keeping
//  the published state on the main actor avoids the usual "publishing
//  from background" pitfalls. The runner is started in a detached Task,
//  so engine work doesn't pin the main actor.
//

import Foundation
import Combine

@MainActor
final class NetSession: ObservableObject, RemoteSeatDelegate {

    // MARK: - Public presentation state

    enum Phase: Equatable {
        case lobby
        case running
        case paused(reason: PauseReason)
        case finished(matchWinner: Int?)
    }

    struct SeatStatus: Equatable {
        let seat: PlayerID
        let kind: SeatKind
        let name: String
        let connected: Bool       // bots and the host's local seat are always "connected"
    }

    enum SeatKind: Equatable {
        case host                 // the local human (this device)
        case remote               // a remote human over the wire
        case bot                  // MonteCarloAgent
    }

    @Published private(set) var phase: Phase = .lobby
    @Published private(set) var seats: [SeatStatus] = []

    // MARK: - Configuration

    enum HostRole {
        case player(seat: PlayerID, human: HumanAgent, name: String)
        case tabletopSpectator
    }

    private var hostRole: HostRole
    private let botDifficulty: MonteCarloAgent.Difficulty

    // MARK: - Per-seat wiring (filled by `seat(_:as:)`)

    private struct SeatAssignment {
        let seat: PlayerID
        var kind: SeatKind
        var name: String
        var remote: RemoteSeat?        // non-nil for .remote
        var botSeed: UInt64?           // set for .bot, also kept for fail-over
    }
    private var assignments: [PlayerID: SeatAssignment] = [:]

    // MARK: - Pause coordination

    /// Set when a remote seat has dropped mid-hand. Resolving the pause
    /// (reconnect, OR host taps fill-with-bot) resumes whoever is suspended
    /// on `awaitResume`.
    private var pauseWaiters: [CheckedContinuation<PauseResolution, Never>] = []

    fileprivate enum PauseResolution {
        case reconnected               // next slice will exercise this
        case filledWithBot
        case sessionCancelled
    }

    // MARK: - Runner lifecycle

    private var runTask: Task<Void, Never>?

    init(hostRole: HostRole, botDifficulty: MonteCarloAgent.Difficulty = .medium) {
        self.hostRole = hostRole
        self.botDifficulty = botDifficulty
        
        // If the host is a player, lock in their seat immediately.
        // If tabletopSpectator, ALL seats remain empty for peers/bots.
        if case .player(let seat, _, let name) = hostRole {
            assignments[seat] = SeatAssignment(
                seat: seat, kind: .host, name: name,
                remote: nil, botSeed: nil)
        }
        publishSeats()
    }

    // MARK: - Lobby

    /// Bind a connected RemoteSeat to a specific seat number. Called once
    /// per remote player from the lobby flow, before `start(...)`. Safe to
    /// re-call if the lobby allows changing seat assignments.
    func seat(_ seat: PlayerID, asRemote remote: RemoteSeat, name: String) {
        if case .player(let hostSeat, _, _) = hostRole {
            precondition(seat != hostSeat,
                         "Host seat is reserved for the local player")
        }

        assignments[seat] = SeatAssignment(
            seat: seat,
            kind: .remote,
            name: name,
            remote: remote,
            botSeed: nil
        )

        publishSeats()
    }

    /// Mark any unassigned seat as a bot. Call after all human peers have
    /// joined, OR rely on `start(...)` to do it implicitly.
    func fillEmptySeatsWithBots(seedBase: UInt64) {
        for seat in Seats.all where assignments[seat] == nil {
            assignments[seat] = SeatAssignment(
                seat: seat, kind: .bot, name: defaultBotName(for: seat),
                remote: nil, botSeed: seedBase &+ UInt64(seat.raw) &* 1_009)
        }
        publishSeats()
    }
    
    // Add this to NetSession.swift to allow the UI to update the role before starting
    func setHostRole(_ role: HostRole) {
        self.hostRole = role
        // Re-publish seats based on the new role
        if case .player(let seat, _, let name) = role {
            assignments[seat] = SeatAssignment(seat: seat, kind: .host, name: name, remote: nil, botSeed: nil)
        } else {
            // Free up seat 0 if switching to tabletop
            assignments[PlayerID(0)] = nil
        }
        publishSeats()
    }

    // MARK: - Start a hand

    /// Begin one hand. Any unassigned seats are filled with bots. Each
    /// RemoteSeat is started and told its assignment + seat names.
    func start(dealSeed: UInt64, dealer: PlayerID = PlayerID(0)) {
        guard runTask == nil else { return }
        fillEmptySeatsWithBots(seedBase: dealSeed)

        phase = .running

        runTask = Task { [weak self] in
            guard let self else { return }
            
            // 1. DETACH the receive loops so they don't freeze the host setup!
            for assn in self.assignments.values where assn.kind == .remote {
                if let r = assn.remote {
                    Task { await r.start(delegate: self) }
                }
            }

            // 2. Guarantee handshakes are queued BEFORE the engine starts.
            // This prevents .handStarted from arriving late and erasing the first .observation.
            let names = self.seatNamesArray()
            await withTaskGroup(of: Void.self) { group in
                for assn in self.assignments.values where assn.kind == .remote {
                    if let r = assn.remote {
                        group.addTask {
                            await r.sendSeatAssignment(seatNames: names)
                            await r.sendHandStarted()
                        }
                    }
                }
            }

            // 3. Safely start the engine. The clients are now fully prepared.
            let agents = self.buildAgents()
            
            var spectatorSeats = self.assignments.values
                .filter { $0.kind == .remote }
                .map(\.seat)
                
            switch self.hostRole {
            case .player(let seat, _, _):
                spectatorSeats.append(seat) // Host needs their own frames
            case .tabletopSpectator:
                // Tabletop needs frames to render the central table.
                if !spectatorSeats.contains(PlayerID(0)) {
                    spectatorSeats.append(PlayerID(0))
                }
            }

            let runner = GameRunner(agents: agents)
            do {
                let final = try await runner.playHand(
                    dealer: dealer,
                    dealSeed: dealSeed,
                    spectators: spectatorSeats,
                    onSeatView: { [weak self] seat, view in
                        await self?.dispatchObservation(seat: seat, view: view)
                    })
                await self.handFinished(final)
            } catch {
                await self.handFailed(error)
            }
        }
    }

    /// Stop the current hand and tear down all RemoteSeat connections.
    /// Safe to call from any state.
    func stop() {
        runTask?.cancel()
        runTask = nil
        // Wake any pause waiter so the runner's Task can exit cleanly.
        resolveAllPauseWaiters(with: .sessionCancelled)
        for assn in assignments.values {
            if let r = assn.remote { Task { await r.stop() } }
        }
        phase = .lobby
    }

    // MARK: - Frame dispatch

    private func dispatchObservation(seat: PlayerID, view: PlayerView) async {
        // Handle local host UI observation
        switch hostRole {
        case .player(let hostSeat, _, _):
            if seat == hostSeat {
                forwardHostFrame(view)
                return // Host seat doesn't have a remote channel
            }
        case .tabletopSpectator:
            // Forward the redacted view to the iPad's tabletop UI
            if seat == PlayerID(0) {
                forwardHostFrame(view.asSpectator())
                // DO NOT return early here! Seat 0 might be a connected
                // iPhone peer that *also* needs this frame unredacted.
            }
        }

        // Forward to remote peers
        guard let assn = assignments[seat],
              assn.kind == .remote,
              let r = assn.remote else { return }
        await r.sendObservation(view)
    }

    // MARK: - Agent assembly

    private func buildAgents() -> [PlayerAgent] {
        Seats.all.map { seat in
            guard let assn = assignments[seat] else {
                preconditionFailure("Seat \(seat.raw) was not assigned before start")
            }
            switch assn.kind {
            case .host:
                guard case .player(_, let human, _) = hostRole else {
                    preconditionFailure("Seat assigned as host, but hostRole is spectator")
                }
                return human
            case .remote:
                guard let r = assn.remote else {
                    preconditionFailure("Remote seat \(seat.raw) has no channel")
                }
                return PauseAwareRemoteAgent(
                    name: assn.name, seat: seat, channel: r, session: self)
            case .bot:
                let seed = assn.botSeed ?? UInt64(seat.raw &+ 1)
                return MonteCarloAgent(
                    name: assn.name, difficulty: botDifficulty, seed: seed)
            }
        }
    }

    // MARK: - Pause / resume (RemoteSeatDelegate)

    nonisolated func remoteSeatDisconnected(_ seat: RemoteSeat, error: Error) async {
        await onRemoteDisconnected(seat: seat.seat)
    }

    private func onRemoteDisconnected(seat: PlayerID) async {
        guard let assn = assignments[seat], assn.kind == .remote else { return }
        let reason: PauseReason = .playerDisconnected(seat: seat, name: assn.name)
        phase = .paused(reason: reason)
        publishSeats(overrideConnected: [seat: false])

        // Tell every other remote player the table is paused.
        for other in assignments.values
            where other.kind == .remote && other.seat != seat {
            if let r = other.remote { await r.sendPause(reason: reason) }
        }
    }

    /// Called by PauseAwareRemoteAgent when its underlying request throws.
    /// Suspends the runner here, off the runner's Task, until the pause is
    /// resolved one way or another.
    fileprivate func awaitResume(for seat: PlayerID) async -> PauseResolution {
        await withCheckedContinuation { (cont: CheckedContinuation<PauseResolution, Never>) in
            self.pauseWaiters.append(cont)
        }
    }

    fileprivate func fallbackBotMoveIfNeeded(for seat: PlayerID, view: PlayerView) async -> Move? {
        guard let assn = assignments[seat], assn.kind == .bot else { return nil }
        let bot = MonteCarloAgent(
            name: assn.name,
            difficulty: botDifficulty,
            seed: assn.botSeed ?? UInt64(seat.raw &+ 1))
        return await bot.chooseMove(from: view)
    }

    /// UI affordance for v1: convert the dropped seat into a bot and
    /// continue. The runner's suspended chooseMove resumes; the new agent
    /// is consulted from this move forward.
    func resumeWithBot() {
        guard case .paused(let reason) = phase,
              case .playerDisconnected(let droppedSeat, _) = reason else { return }

        if var assn = assignments[droppedSeat] {
            assn.kind = .bot
            assn.name = defaultBotName(for: droppedSeat)
            assn.remote = nil
            assn.botSeed = UInt64.random(in: 0...UInt64.max)
            assignments[droppedSeat] = assn
        }
        phase = .running
        publishSeats()
        // Broadcast resume to remaining remote seats.
        for assn in assignments.values where assn.kind == .remote {
            if let r = assn.remote { Task { await r.sendResume() } }
        }
        resolveAllPauseWaiters(with: .filledWithBot)
    }

    private func resolveAllPauseWaiters(with res: PauseResolution) {
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume(returning: res) }
    }

    // MARK: - Hand completion

    private func handFinished(_ final: GameState) async {
        runTask = nil
        phase = .finished(matchWinner: final.matchWinner)
        // Transition the host's bound GameSession to its end-of-hand
        // state. The host's GameSession has no runner of its own in this
        // mode, so it never triggers this transition by itself.
        forwardHostHandFinished(final)
        for assn in assignments.values where assn.kind == .remote {
            if let r = assn.remote {
                await r.sendHandFinished(
                    matchScore: final.matchScore,
                    matchWinner: final.matchWinner)
            }
        }
    }

    private func handFailed(_ error: Error) async {
        runTask = nil
        phase = .lobby
        // Best-effort: tell remote peers the table tore down.
        for assn in assignments.values where assn.kind == .remote {
            if let r = assn.remote { await r.stop() }
        }
        assertionFailure("NetSession runner failed: \(error)")
    }

    // MARK: - Helpers

    private func seatNamesArray() -> [String] {
        Seats.all.map { assignments[$0]?.name ?? defaultBotName(for: $0) }
    }

    private func defaultBotName(for seat: PlayerID) -> String {
        ["South-bot", "West-bot", "North-bot", "East-bot"][seat.raw]
    }

    private func publishSeats(overrideConnected: [PlayerID: Bool] = [:]) {
        seats = Seats.all.map { seat in
            let a = assignments[seat]
            return SeatStatus(
                seat: seat,
                kind: a?.kind ?? .bot,
                name: a?.name ?? defaultBotName(for: seat),
                connected: overrideConnected[seat] ?? true)
        }
    }
}

// MARK: - PauseAwareRemoteAgent
//
// PauseAwareRemoteAgent catches .disconnected from the channel, hands
// control to NetSession.awaitResume, and acts on the resolution:
//
//   • reconnected  — try the same channel again with a fresh requestID.
//                    (Channel re-binding happens in NetSession when the
//                    next slice wires up MPC reconnect; this code is
//                    correct ahead of that — it will just keep failing
//                    over until a real reconnect path exists.)
//
//   • filledWithBot — this seat is now a bot. The current decision is
//                     dispatched to a fresh MC agent built on the spot,
//                     so the engine never sees a missing move.
//
//   • sessionCancelled — the session is shutting down; propagate by
//                        returning a benign "pass" if legal, otherwise
//                        any legal move (the runner will be cancelled
//                        before its return isC observed).
//
// Kept private to NetSession.swift on purpose — its contract leans on
// NetSession internals.

private struct PauseAwareRemoteAgent: PlayerAgent {

    let name: String
    let seat: PlayerID
    let channel: RemoteSeat
    weak var session: NetSession?

    func chooseMove(from view: PlayerView) async -> Move {
        precondition(!view.legalMoves.isEmpty,
                     "PauseAwareRemoteAgent asked to move with no legal moves")
        while true {
            if let move = await session?.fallbackBotMoveIfNeeded(for: seat, view: view) {
                return move
            }
            do {
                return try await channel.requestMove(view: view)
            } catch {
                guard let session else { return view.legalMoves[0] }
                let res = await session.awaitResume(for: seat)
                switch res {
                case .reconnected:
                    continue  // retry the same channel
                case .filledWithBot:
                    if let move = await session.fallbackBotMoveIfNeeded(for: seat, view: view) {
                        return move
                    }
                    return view.legalMoves[0]
                case .sessionCancelled:
                    return view.legalMoves.first { $0.isPass } ?? view.legalMoves[0]
                }
            }
        }
    }
}
