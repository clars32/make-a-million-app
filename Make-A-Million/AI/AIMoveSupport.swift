//
//  AIMoveSupport.swift
//  Make-a-Million
//
//  Tiny read-only conveniences over Move for the AI. No rules here — just
//  pattern-match shorthands so the policy and agent stay readable.
//

import Foundation

extension Move {
    var isPass: Bool {
        if case .bid(.pass) = self { return true }
        return false
    }
    /// The bid amount, if this is a numeric bid.
    var bidAmount: Int? {
        if case .bid(.bid(let n)) = self { return n }
        return nil
    }
    /// The card, if this is a `.play`.
    var playedCard: Card? {
        if case .play(let c) = self { return c }
        return nil
    }
    /// The colors, if this is a `.discardWidow`.
    var discardCards: [Card]? {
        if case .discardWidow(let cs) = self { return cs }
        return nil
    }
}
