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

    // Optional end-of-hand bid recap (populated host-side, where the full
    // result is known). bidAmount/bidder identify the winning bid;
    // biddingTeamPoints is what that team actually captured this hand, so the
    // view can show "made it" vs "set".
    var bidAmount: Int? = nil
    var bidder: PlayerID? = nil
    var biddingTeamPoints: Int? = nil
    var handScore: [Int: Int] = [:]
    var trump: CardColor? = nil
}

extension HandCompleteSnapshot {
    static let matchTarget = 1_000_000

    init(final state: GameState) {
        let publicView = state.view(for: PlayerID(0))
        let handScore = publicView.liveHandScore
        let biddingTeam = state.highBidder.map { Seats.team(of: $0) }
        self.init(
            matchScore: state.matchScore,
            matchWinner: state.matchWinner,
            bidHistory: state.bidHistory,
            opener: Seats.next(state.dealer),
            debugReveal: state.debugReveal(),
            bidAmount: state.highBid,
            bidder: state.highBidder,
            biddingTeamPoints: biddingTeam.map { handScore[$0, default: 0] },
            handScore: handScore,
            trump: state.trump)
    }

    var biddingTeam: Int? {
        bidder.map { Seats.team(of: $0) }
    }

    var madeBid: Bool? {
        guard let bidAmount, let biddingTeamPoints else { return nil }
        return biddingTeamPoints >= bidAmount
    }

    func handPoints(for team: Int) -> Int? {
        if let points = handScore[team] { return points }
        if team == biddingTeam { return biddingTeamPoints }
        return nil
    }

    func scoreDelta(for team: Int) -> Int? {
        guard let bidAmount, let biddingTeam, let biddingTeamPoints else {
            return handPoints(for: team)
        }

        if team == biddingTeam {
            return biddingTeamPoints >= bidAmount ? biddingTeamPoints : -bidAmount
        }

        return handPoints(for: team)
    }

    func previousMatchScore(for team: Int) -> Int? {
        guard let delta = scoreDelta(for: team) else { return nil }
        return matchScore[team, default: 0] - delta
    }
}
