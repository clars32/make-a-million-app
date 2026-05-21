//
//  PlayerView+Spectator.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/20/26.
//

extension PlayerView {
    /// Returns a redacted copy of this view safe for a non-playing spectator (the tabletop).
    func asSpectator() -> PlayerView {
        PlayerView(
            me: self.me,
            myHand: [],           // REDACTED: Spectators see no hand
            phase: self.phase,
            toAct: self.toAct,
            trump: self.trump,
            highBid: self.highBid,
            highBidder: self.highBidder,
            passed: self.passed,
            opener: self.opener,
            bidHistory: self.bidHistory,
            widow: self.widow,
            currentTrick: self.currentTrick,
            completedTrickCount: self.completedTrickCount,
            completedTricks: self.completedTricks,
            matchScore: self.matchScore,
            legalMoves: []        // REDACTED: Spectators cannot act
        )
    }
}
