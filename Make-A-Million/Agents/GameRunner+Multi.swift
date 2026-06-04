//
//  GameRunner+Multi.swift
//  Make-a-Million
//
//  The single-spectator emission path in GameRunner exists for the local
//  human (one device, one viewer). Networked play has up to four viewers
//  watching the same hand from four different seats, each with their own
//  redacted projection. This extension adds the multi-spectator path.
//
//  ENGINE GUARANTEES PRESERVED:
//
//   • Same emission points as the single-spectator version: one frame
//     per spectator after the initial deal, then one per spectator after
//     each applied move. Exactly one move happens between consecutive
//     frames PER SEAT — pacing logic on the consumer side stays correct.
//
//   • Still uses each spectator's OWN `view(for:)`. No seat ever sees
//     hidden information that belongs to another seat. This is the same
//     redaction the Monte Carlo agent depends on, used four times
//     instead of once.
//
//   • The runner never blocks on consumers. `await sink(...)` lets each
//     consumer suspend the runner exactly the way the single-spectator
//     path does — a remote consumer with slow bytes pauses everyone
//     until its frame is on the wire, which is correct behavior for a
//     turn-based table game and identical to the existing model.
//
//  The closure type drops the @MainActor constraint the single-spectator
//  path has. NetSession sends frames from its own actor, not from
//  MainActor, and GameSession's existing usage is unaffected because it
//  calls the older overload.
//

import Foundation

extension GameRunner {
    
    /// Play one hand to completion, emitting one PlayerView per spectator
    /// after the initial deal and after every applied move.
    ///
    /// - Parameters:
    ///   - spectators: seats whose redacted views should be emitted.
    ///     Empty means no emission (equivalent to a pure headless run).
    ///   - onSeatView: sink called once per (seat, view) pair. Awaited,
    ///     so a slow consumer naturally paces the runner.
    func playHand(dealer: PlayerID,
                  dealSeed: UInt64,
                  carryScore: [Int: Int] = [0: 0, 1: 0],
                  misdealRule: MisdealRule = .standard,
                  endgameRule: EndgameTiebreak = .standard,
                  spectators: [PlayerID],
                  onSeatView: (@Sendable (PlayerID, PlayerView) async -> Void)?)
    async throws -> GameState {

        var state = GameState.newHand(dealer: dealer,
                                      seed: dealSeed,
                                      carryScore: carryScore,
                                      misdealRule: misdealRule,
                                      endgameRule: endgameRule)
        
        // Initial deal frame — one per spectator.
        if let sink = onSeatView {
            for s in spectators { await sink(s, state.view(for: s)) }
        }
        
        // Same safety ceiling as the single-spectator path. A hand has a
        // bounded number of legal transitions; busting the ceiling means
        // a state-machine bug, not legitimate play.
        var steps = 0
        let maxSteps = 1_000
        
        while state.phase != .handComplete {
            // Auto-misdeal: hold the notice visible, then apply the forced
            // redeal. All spectators see the misdeal frame and the post-
            // redeal frame, exactly as if it were any other transition.
            if state.phase == .misdealDecision {
                try? await Task.sleep(for: .milliseconds(2200))
                state = try state.applying(.callMisdeal, by: state.toAct)
                if let sink = onSeatView {
                    for s in spectators { await sink(s, state.view(for: s)) }
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
            
            if let sink = onSeatView {
                for s in spectators { await sink(s, state.view(for: s)) }
            }
            
            steps += 1
            if steps > maxSteps {
                throw RunnerError.didNotTerminate(afterSteps: steps,
                                                  stuckIn: state.phase)
            }
        }
        return state
    }
}
