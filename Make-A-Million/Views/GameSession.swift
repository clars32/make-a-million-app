//
//  GameSession.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/19/26.
//


//
//  GameSession.swift
//  Make-a-Million
//
//  Owns one HumanAgent + three MonteCarloAgents and runs a hand via
//  GameRunner on a background task.
//
//  ALSO the PRESENTATION BUFFER. The runner emits the human's redacted view
//  after every move — a fast burst between your turns. This object queues
//  those frames and drains them into `displayView` at a watchable cadence.
//
//  THE GUARDRAIL, restated for this file: the engine NEVER waits on this.
//  The runner is suspended in the human's `chooseMove` waiting for a tap —
//  that is normal think-time it already tolerates by design. Pacing the
//  view changes nothing engine-side. `displayView` only ever advances from
//  the feed; nothing here mutates game state or gates a rule on animation.
//
//  OBSERVATION NOTE (unchanged, still true): `human` is its own
//  ObservableObject; SwiftUI does not propagate through a nested one. The
//  view observes `session.human` DIRECTLY for `pending`, and observes this
//  object for `displayView` / `caughtUp`.
//

import Foundation
import Combine

@MainActor
final class GameSession: ObservableObject {

    let human: HumanAgent

    /// Final state, set only AFTER the last frame has been shown and a brief
    /// settle has elapsed — so the deciding trick is actually seen.
    @Published private(set) var finished: GameState? = nil
    @Published private(set) var running = false

    /// What the table should render right now: the paced, animated state.
    /// Distinct from `human.pending` (the live decision point). Continuous
    /// for the whole hand — never nil between turns, so the hierarchy and
    /// matchedGeometry identities survive.
    @Published private(set) var displayView: PlayerView? = nil

    /// True when the buffer has drained to the live state. The UI arms the
    /// human's controls only when `pending != nil && caughtUp` — so you
    /// watch the bots' burst, then act.
    @Published private(set) var caughtUp = true

    /// The seat the human occupies (constructed first in `start`).
    private let spectator = PlayerID(0)

    /// Pacing knobs. Per-move cadence and the end-of-hand settle. These are
    /// the dials to turn if the game feels too slow or too frantic.
    private let frameInterval: Duration = .milliseconds(500)
    private let settleInterval: Duration = .milliseconds(700)

    /// One place to tune how hard the table plays.
    private let botDifficulty: MonteCarloAgent.Difficulty = .medium

    private var queue: [PlayerView] = []
    private var draining = false
    private var pendingFinal: GameState? = nil

    private var runTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil

    init() {
        human = HumanAgent(name: "You")
    }

    func start(dealSeed: UInt64) {
        guard !running else { return }
        running = true
        finished = nil
        displayView = nil
        caughtUp = true
        queue.removeAll()
        draining = false
        pendingFinal = nil

        let agents: [PlayerAgent] = [
            human,
            MonteCarloAgent(name: "West",  difficulty: botDifficulty,
                            seed: dealSeed &+ 101),
            MonteCarloAgent(name: "North", difficulty: botDifficulty,
                            seed: dealSeed &+ 202),
            MonteCarloAgent(name: "East",  difficulty: botDifficulty,
                            seed: dealSeed &+ 303),
        ]
        let runner = GameRunner(agents: agents)
        let spectator = self.spectator

        runTask = Task {
            do {
                let final = try await runner.playHand(
                    dealer: PlayerID(0),
                    dealSeed: dealSeed,
                    spectator: spectator,
                    onView: { [weak self] view in
                        // Headless emission from the runner's context. Hop
                        // to the main actor and enqueue; never block here.
                        Task { @MainActor in self?.enqueue(view) }
                    })
                await MainActor.run {
                    self.pendingFinal = final
                    self.startDrainIfNeeded()   // ensures the finish path runs
                }
            } catch {
                await MainActor.run { self.running = false }
                assertionFailure("GameRunner threw: \(error)")
            }
        }
    }

    func reset() {
        runTask?.cancel();   runTask = nil
        drainTask?.cancel(); drainTask = nil
        queue.removeAll()
        draining = false
        pendingFinal = nil
        displayView = nil
        finished = nil
        running = false
        caughtUp = true
    }

    // MARK: - Buffer

    private func enqueue(_ view: PlayerView) {
        queue.append(view)
        caughtUp = false
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        guard !queue.isEmpty || pendingFinal != nil else { return }
        draining = true

        drainTask = Task { @MainActor in
            // First frame of a (re)started drain shows immediately, so your
            // own play and the start of a burst feel responsive; subsequent
            // frames are paced.
            while !queue.isEmpty {
                if Task.isCancelled { return }
                let next = queue.removeFirst()
                // No withAnimation here on purpose: the view animates via
                // its `.animation(_, value:)` modifier. One transaction,
                // not two.
                displayView = next
                if queue.isEmpty { break }
                try? await Task.sleep(for: frameInterval)
            }

            draining = false
            caughtUp = queue.isEmpty

            // Hand over only after the last frame has been seen and held.
            if queue.isEmpty, let final = pendingFinal {
                try? await Task.sleep(for: settleInterval)
                if Task.isCancelled { return }
                if self.pendingFinal != nil {   // not reset in the meantime
                    self.finished = final
                    self.running = false
                }
            }
        }
    }
}