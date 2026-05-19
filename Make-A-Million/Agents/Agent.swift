//
//  Agent.swift
//  Make-a-Million
//
//  THE boundary. Every mover in the game — the three bots now, the human
//  player when views arrive, a remote opponent in a later milestone — is a
//  PlayerAgent. They differ ONLY in where the Move comes from. The engine
//  never knows or cares which kind it is talking to.
//
//  Why `async`: a bot can answer instantly; a human cannot — their move
//  arrives later, from a tap, after the UI has rendered and waited. A
//  synchronous protocol would fit the bot and exclude the human, forcing a
//  game-loop rewrite when views arrive. An async protocol fits both: the bot
//  returns immediately, the human's implementation suspends until the UI
//  resumes it. Same protocol, same loop, no rewrite. This is the entire
//  reason the agent layer is built before any view.
//
//  This file does NOT import SwiftUI. It sits on the engine side of the
//  boundary. Agents receive only the redacted PlayerView and return only a
//  Move — never the full GameState, never another seat's hand.
//

import Foundation

protocol PlayerAgent {
    /// Stable identifier, for logging/UI labels. Not the seat — the engine
    /// assigns seats; this is just "who is this agent" for humans to read.
    var name: String { get }

    /// Given everything this seat is allowed to know, choose one legal move.
    ///
    /// Contract:
    ///   - The returned Move MUST be an element of `view.legalMoves`.
    ///     The engine re-validates and will throw on an illegal move, but a
    ///     well-behaved agent never produces one.
    ///   - `view.legalMoves` is guaranteed non-empty whenever it is this
    ///     agent's turn (the engine guarantees a mover always has a move).
    func chooseMove(from view: PlayerView) async -> Move
}
