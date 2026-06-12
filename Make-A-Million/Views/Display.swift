//
//  Display.swift
//  Make-a-Million
//
//  Presentation-only. Turns engine value types into readable text. Lives on
//  the VIEW side of the boundary deliberately — the engine never spells a
//  card for a human; that is a UI concern.
//

import SwiftUI

extension CardColor {
    var displayName: String {
        switch self {
        case .red: "Red"; case .yellow: "Yellow"
        case .black: "Black"; case .green: "Green"
        }
    }
    var swatch: Color {
        switch self {
        case .red: .red; case .yellow: .yellow
        case .black: .primary; case .green: .green
        }
    }
}

extension Card.Rank {
    /// Short label as it reads at the table.
    var label: String {
        switch self {
        case .one: "1"; case .two: "2"; case .three: "3"; case .four: "4"
        case .money5k: "$5"; case .seven: "7"; case .eight: "8"
        case .nine: "9"; case .money10k: "$10"; case .eleven: "11"
        case .money15k: "$15"; case .money30k: "$30"; case .money40k: "$40"
        }
    }
}

extension Card {
    var label: String {
        switch self {
        case .colored(let c, let r): "\(c.displayName) \(r.label)"
        case .tiger: "TIGER"
        case .bull:  "BULL"
        case .bear:  "BEAR"
        }
    }
    var shortLabel: String {
        switch self {
        case .colored(_, let r): r.label
        case .tiger: "TGR"; case .bull: "BUL"; case .bear: "BER"
        }
    }
    var tint: Color {
        switch self {
        case .colored(let c, _): c.swatch
        case .tiger: .orange
        case .bull:  .blue
        case .bear:  .brown
        }
    }
}

extension DiscardAnnouncement {
    /// The announcement as it would be spoken at the table. Money cards are
    /// rendered as card faces next to this text, so they only get a lead-in
    /// here. "No trump or money" is information too — everyone heard nothing.
    var summaryText: String {
        var parts: [String] = []
        if trumpCount > 0 { parts.append("\(trumpCount) trump") }
        if !moneyCards.isEmpty { parts.append("money:") }
        guard !parts.isEmpty else { return "Discarded: no trump or money" }
        return "Discarded: " + parts.joined(separator: " · ")
    }
}

extension Move {
    var label: String {
        switch self {
        case .bid(.pass): "Pass"
        case .bid(.bid(let n)): "Bid $\(n / 1000)k"
        case .callMisdeal: "Call misdeal (redeal)"
        case .declineMisdeal: "Decline — keep this hand"
        case .discardWidow(let cs): "Discard " + cs.map(\.shortLabel).joined(separator: ", ")
        case .nameTrump(let c): "Trump: \(c.displayName)"
        case .play(let c): c.label
        }
    }
}

extension Phase {
    var headline: String {
        switch self {
        case .bidding: "Bidding"
        case .misdealDecision: "Misdeal"
        case .widowDiscard: "Discard three from the widow"
        case .namingTrump: "Name the trump color"
        case .trickPlay: "Trick play"
        case .handComplete: "Hand complete"
        }
    }
}
