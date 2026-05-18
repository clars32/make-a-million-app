//
//  GameRunner.swift
//  Make-a-Million
//
//  Drives a hand to completion: ask whoever is on turn for a move via their
//  agent, apply it, repeat until phase == .handComplete. This is the
//  headless game loop. Views, when they arrive, do NOT replace this — the
//  human is just one of the four agents, and this same loop runs unchanged.
//
//  No SwiftUI. The loop is engine-side. It only ever hands an agent a
//  PlayerView and only ever receives a Move back.
//

import Foundation

struct GameRunner {

    /// The four seated agents, indexed by seat 0..<4.
    let agents: [PlayerAgent]

    init(agents: [PlayerAgent]) {
        precondition(agents.count == Seats.count,
                     "Make-a-Million seats exactly \(Seats.count) agents")
        self.agents = agents
    }

    /// Play one hand to completion from a fresh deal. Returns the final state
    /// (phase == .handComplete, scores settled). Pure with respect to the
    /// seeds: (dealSeed, agent seeds) fully reproduces the hand.
    func playHand(dealer: PlayerID,
                  dealSeed: UInt64,
                  carryScore: [Int: Int] = [0: 0, 1: 0]) async throws -> GameState {

        var state = GameState.newHand(dealer: dealer,
                                      seed: dealSeed,
                                      carryScore: carryScore)

        // Safety bound: a hand is 4 bids-ish + misdeal + discard + trump + 52
        // card plays. A few hundred steps is a generous ceiling; exceeding it
        // means a state-machine bug, and we want a loud failure, not a hang.
        var steps = 0
        let maxSteps = 1_000

        while state.phase != .handComplete {
            let mover = state.toAct
            let view = state.view(for: mover)
            let move = await agents[mover.raw].chooseMove(from: view)
            state = try state.applying(move, by: mover)

            steps += 1
            if steps > maxSteps {
                throw RunnerError.didNotTerminate(afterSteps: steps,
                                                  stuckIn: state.phase)
            }
        }
        return state
    }

    /// Play a full match: repeated hands, dealer rotating left each hand,
    /// until a team reaches 1,000,000. Returns the winning team and the
    /// final state.
    func playMatch(firstDealer: PlayerID = PlayerID(0),
                   baseSeed: UInt64) async throws -> (winner: Int, finalState: GameState) {
        var dealer = firstDealer
        var carry: [Int: Int] = [0: 0, 1: 0]
        var handIndex: UInt64 = 0
        let maxHands: UInt64 = 500   // sanity ceiling; a real match ends far sooner

        while true {
            let state = try await playHand(
                dealer: dealer,
                dealSeed: baseSeed &+ handIndex,
                carryScore: carry)

            carry = state.matchScore
            if let w = state.matchWinner {
                return (w, state)
            }
            dealer = Seats.next(dealer)   // deal passes left
            handIndex += 1
            if handIndex > maxHands {
                throw RunnerError.matchDidNotConclude(afterHands: handIndex)
            }
        }
    }
}

enum RunnerError: Error, Equatable {
    case didNotTerminate(afterSteps: Int, stuckIn: Phase)
    case matchDidNotConclude(afterHands: UInt64)
}
