//
//  GameRunner.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/19/26.
//


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
//  PRESENTATION FEED (added):
//
//   An OPTIONAL, headless observer. If a `spectator` seat and an `onView`
//   sink are supplied, the runner emits that seat's ALREADY-REDACTED
//   PlayerView once for the initial deal and once after every applied move.
//   It is the same projection an agent receives — no hidden information
//   crosses, and the emission point stays correct if this ever goes remote.
//
//   This does NOT change the loop, does NOT pace anything, and does NOT
//   wait on a consumer. The runner emits and moves on; pacing is entirely
//   the consumer's problem. Defaults are nil, so `playMatch` and any other
//   caller are completely unaffected.
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
    ///
    /// - Parameters:
    ///   - spectator: if set, the seat whose redacted view is emitted.
    ///   - onView: headless sink for emitted views. Called from the runner's
    ///     own context; the consumer is responsible for hopping actors and
    ///     for any pacing. The runner never blocks on it.
    func playHand(dealer: PlayerID,
                  dealSeed: UInt64,
                  carryScore: [Int: Int] = [0: 0, 1: 0],
                  misdealRule: MisdealRule = .standard,
                  spectator: PlayerID? = nil,
                  onView: (@Sendable @MainActor (PlayerView) async -> Void)? = nil) async throws -> GameState {

        var state = GameState.newHand(dealer: dealer,
                                      seed: dealSeed,
                                      carryScore: carryScore,
                                      misdealRule: misdealRule)

        // Initial deal frame, so the consumer can show the dealt hand /
        // opening of bidding rather than starting one move in.
        if let s = spectator, let sink = onView {
            await sink(state.view(for: s))
        }

        // Safety bound: a hand is 4 bids-ish + misdeal + discard + trump + 52
        // card plays. A few hundred steps is a generous ceiling; exceeding it
        // means a state-machine bug, and we want a loud failure, not a hang.
        var steps = 0
        let maxSteps = 1_000

        while state.phase != .handComplete {
            // Auto-misdeal: the rule fires before bidding, no agent is asked.
            // The notice frame was already emitted (initial deal, or the
            // post-move frame of a prior redeal). Hold it visible briefly,
            // then apply the forced redeal and emit the next frame.
            if state.phase == .misdealDecision {
                try? await Task.sleep(for: .milliseconds(2200))
                state = try state.applying(.callMisdeal, by: state.toAct)
                if let s = spectator, let sink = onView {
                    await sink(state.view(for: s))
                }
                steps += 1
                if steps > maxSteps {
                    throw RunnerError.didNotTerminate(afterSteps: steps,
                                                      stuckIn: state.phase)
                }
                continue
            }

            let mover = state.toAct
            let view = state.view(for: mover)
            let move = await agents[mover.raw].chooseMove(from: view)
            state = try state.applying(move, by: mover)

            // Post-move frame. This is what makes single-step animation
            // possible: between any two consecutive emitted views exactly
            // one move has happened.
            if let s = spectator, let sink = onView {
                await sink(state.view(for: s))
            }

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
                       baseSeed: UInt64,
                   misdealRule: MisdealRule = .standard) async throws -> (winner: Int, finalState: GameState) {
        var dealer = firstDealer
        var carry: [Int: Int] = [0: 0, 1: 0]
        var handIndex: UInt64 = 0
        let maxHands: UInt64 = 500   // sanity ceiling; a real match ends far sooner
        
        while handIndex < maxHands {
            let state = try await playHand(
                dealer: dealer,
                dealSeed: baseSeed &+ handIndex,
                carryScore: carry,
                misdealRule: misdealRule)
            if let winner = state.matchWinner {
                return (winner, state)
            }
            carry = state.matchScore
            dealer = Seats.next(dealer)
            handIndex &+= 1
        }

        throw RunnerError.matchDidNotConclude(afterHands: maxHands)
    }
}

enum RunnerError: Error, Equatable {
    case didNotTerminate(afterSteps: Int, stuckIn: Phase)
    case matchDidNotConclude(afterHands: UInt64)
}
