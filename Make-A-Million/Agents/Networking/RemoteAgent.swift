//
//  RemoteAgent.swift
//  Make-a-Million
//
//  The fourth shape of PlayerAgent. To recap the lineage:
//
//   • RandomAgent      — answers instantly from a seeded RNG.
//   • MonteCarloAgent  — answers after rolling out determinized worlds.
//   • HumanAgent       — answers when the LOCAL tap arrives.
//   • RemoteAgent      — answers when a REMOTE tap arrives over the wire.
//
//  GameRunner sees no difference. That is the entire point of the agent
//  layer existing before any UI or network code — adding remote play is
//  a new agent + a transport, NOT a loop rewrite. The protocol's `async`
//  was put there for exactly this case.
//
//  DISCONNECT HANDLING: this file deliberately treats a thrown transport
//  error as fatal. The host's NetSession is responsible for catching it
//  one layer up, pausing the table for everyone, waiting for the peer to
//  return, and then re-driving the same chooseMove. Making the agent
//  itself loop over reconnects would smear policy across two files for
//  no benefit, and it would also make a stale Move possible (one from
//  before the pause) — the NetSession is the one place that knows
//  whether the request is still valid.
//

import Foundation

struct RemoteAgent: PlayerAgent {

    let name: String
    let seat: PlayerID
    private let channel: RemoteSeat

    init(name: String, seat: PlayerID, channel: RemoteSeat) {
        self.name = name
        self.seat = seat
        self.channel = channel
    }

    func chooseMove(from view: PlayerView) async -> Move {
        precondition(!view.legalMoves.isEmpty,
                     "RemoteAgent asked to move with no legal moves")
        do {
            return try await channel.requestMove(view: view)
        } catch {
            // NetSession is expected to intercept disconnects before the
            // continuation can throw out to here. If we land in this
            // branch the higher layer is missing its pause hook — fail
            // loudly in development so it gets fixed, rather than
            // silently returning an illegal default move and corrupting
            // the hand.
            preconditionFailure(
                "RemoteAgent saw transport error \(error) without host pause intervention — "
                + "NetSession must catch RemoteSeat disconnects before they reach the agent")
        }
    }
}
