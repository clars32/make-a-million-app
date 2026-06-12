//
//  AnimalCuePacing.swift
//  Make-a-Million
//

import Foundation

struct AnimalCuePauseTracker {
    private var didStampedeCurrentTrick = false
    private var lastPlayCount = 0

    mutating func reset() {
        didStampedeCurrentTrick = false
        lastPlayCount = 0
    }

    mutating func holdDuration(after view: PlayerView, animationsEnabled: Bool) -> Duration? {
        guard animationsEnabled else {
            reset()
            return nil
        }

        let trick = view.currentTrick
        let playCount = trick?.plays.count ?? 0
        if playCount <= 1 || playCount < lastPlayCount {
            didStampedeCurrentTrick = false
        }
        lastPlayCount = playCount

        guard let trick, let latest = trick.plays.last else { return nil }

        if !didStampedeCurrentTrick,
           trick.hasActiveBull,
           trick.baseMoneyValue >= 40_000 {
            didStampedeCurrentTrick = true
            return .milliseconds(5_000)
        }

        switch latest.card {
        case .tiger, .bull, .bear:
            return .milliseconds(2_000)
        case .colored:
            return nil
        }
    }
}

extension Trick {
    var baseMoneyValue: Int {
        plays.reduce(0) { $0 + $1.card.moneyValue }
    }

    var hasActiveBull: Bool {
        var lastModifier: Card?
        for play in plays {
            if play.card == .bull { lastModifier = .bull }
            if play.card == .bear { lastModifier = .bear }
        }
        return lastModifier == .bull
    }
}
