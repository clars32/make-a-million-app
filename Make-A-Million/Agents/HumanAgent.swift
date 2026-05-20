//
//  HumanAgent.swift
//  Make-a-Million
//
//  The human is just a fourth PlayerAgent. Its chooseMove does not compute a
//  move — it SUSPENDS until the UI delivers one (a tap). This is the entire
//  reason PlayerAgent.chooseMove is `async`: a bot returns instantly, the
//  human returns "later", and the GameRunner loop does not care which.
//
//  Bridging detail: the engine/agent side is concurrency-domain code; the UI
//  is @MainActor. HumanAgent is the boundary object. It exposes, on the main
//  actor, the PlayerView the human must act on, and a callback the UI calls
//  when the human taps a move. Internally it parks a continuation that
//  chooseMove is awaiting and resumes it when that callback fires.
//
//  This file is allowed to import SwiftUI ONLY for @MainActor / ObservableObject
//  plumbing — it contains no views. It is the seam, not the surface.
//

import Foundation
import Combine

/// Lets GameSession pace bot frames before the human's decision point.
@MainActor
protocol PresentationCoordinator: AnyObject {
    func drainBeforeHumanTurn() async
    func humanTurnDidBegin()
    func humanCommittedMove(_ move: Move, from view: PlayerView)
    func humanTurnDidEnd()
}

@MainActor
final class HumanAgent: ObservableObject, PlayerAgent {

    nonisolated let name: String

    weak var coordinator: (any PresentationCoordinator)?

    /// The view the human is currently being asked to act on, or nil when it
    /// is not the human's turn. The UI observes this to know what to render
    /// and which moves to offer.
    @Published private(set) var pending: PlayerView? = nil

    /// The continuation chooseMove is suspended on, waiting for a tap.
    private var waiter: CheckedContinuation<Move, Never>? = nil

    init(name: String = "You") { self.name = name }

    // MARK: PlayerAgent

    /// Called by GameRunner off the main actor. Hop to the main actor, publish
    /// the view for the UI, and suspend until `submit(_:)` is called.
    nonisolated func chooseMove(from view: PlayerView) async -> Move {
        await beginHumanTurn(with: view)
        let move = await withCheckedContinuation { (cont: CheckedContinuation<Move, Never>) in
            Task { @MainActor in self.waiter = cont }
        }
        await finishHumanTurn()
        return move
    }

    @MainActor
    private func beginHumanTurn(with view: PlayerView) async {
        await coordinator?.drainBeforeHumanTurn()
        present(view)
        coordinator?.humanTurnDidBegin()
    }

    @MainActor
    private func finishHumanTurn() {
        clear()
        coordinator?.humanTurnDidEnd()
    }

    // MARK: UI-facing surface (main actor)

    /// The UI calls this when the human taps a legal move. Resumes the
    /// suspended chooseMove. Ignored if it isn't actually the human's turn or
    /// the move isn't legal (defensive — the UI should only offer legal moves).
    func submit(_ move: Move) {
        guard let view = pending,
              view.legalMoves.contains(move),
              let cont = waiter else { return }
        coordinator?.humanCommittedMove(move, from: view)
        waiter = nil
        cont.resume(returning: move)
    }

    private func present(_ view: PlayerView) { pending = view }
    private func clear() { pending = nil }
}
