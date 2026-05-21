//
//  HandCompleteSnapshot.swift
//  Make-a-Million
//
//  Small value type the end-of-hand view renders. Exists because both
//  GameSession (which has a full GameState available) and ClientSession
//  (which only ever has the public PlayerView projection plus a winner
//  delivered over the wire) need to drive the same end-of-hand UI.
//
//  Everything here is PUBLIC information at the table: the settled
//  match score, who won the match (if anyone), the bidding record, who
//  opened, who dealt. `debugReveal` is the one piece of HIDDEN info
//  and is non-nil only on the host side — clients hand over nil, which
//  the view handles by simply omitting the reveal panel. The redaction
//  invariant that's protected the AI from the start still holds: no
//  client receives dealtHands or dealtWidow over the wire.
//

import Foundation

struct HandCompleteSnapshot {
    let matchScore: [Int: Int]
    let matchWinner: Int?
    let bidHistory: [BidRecord]
    let opener: PlayerID
    let debugReveal: DebugReveal?
}
