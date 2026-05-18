//
//  GameSession.swift
//  Make-a-Million
//
//  Owns one HumanAgent + three RandomAgents and runs a hand via GameRunner
//  on a background task.
//
//  OBSERVATION NOTE: `human` is its own ObservableObject. SwiftUI does NOT
//  propagate observation through a nested ObservableObject — a view holding
//  only `@StateObject session` will NOT re-render when `session.human.pending`
//  changes. The view must observe the HumanAgent DIRECTLY (the view attaches
//  its own @ObservedObject to `session.human`). This nested-observation gap
//  was the "Deal a hand does nothing" bug: the agent published correctly,
//  the view simply was not subscribed to it.
//

import Foundation
import Combine

@MainActor
final class GameSession: ObservableObject {

    let human: HumanAgent
    @Published private(set) var finished: GameState? = nil
    @Published private(set) var running = false

    private var task: Task<Void, Never>? = nil

    init() {
        human = HumanAgent(name: "You")
    }

    func start(dealSeed: UInt64) {
        guard !running else { return }
        running = true
        finished = nil

        let agents: [PlayerAgent] = [
            human,
            RandomAgent(name: "West",  seed: dealSeed &+ 101),
            RandomAgent(name: "North", seed: dealSeed &+ 202),
            RandomAgent(name: "East",  seed: dealSeed &+ 303),
        ]
        let runner = GameRunner(agents: agents)

        task = Task {
            do {
                let final = try await runner.playHand(
                    dealer: PlayerID(0), dealSeed: dealSeed)
                self.finished = final
                self.running = false
            } catch {
                self.running = false
                assertionFailure("GameRunner threw: \(error)")
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        finished = nil
        running = false
    }
}
