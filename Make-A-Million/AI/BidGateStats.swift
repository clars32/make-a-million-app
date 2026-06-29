//
//  BidGateStats.swift
//  Make-a-Million
//
//  Flip-rate instrument for the bid staying-power gate (`bidEntryMargin`).
//
//  The gate's whole point is the human-partner case: a marginal lead bid makes
//  the human partner defer (a pass is permanent), then the bot folds and gifts
//  the contract to the opponents. That cost is INVISIBLE to symmetric self-play
//  — a bot partner doesn't defer to a signal — so the arena's win-rate can't
//  measure the fix. What self-play CAN tell us is how OFTEN the gate would flip
//  a lead bid into a pass, which is the number we need to judge "is it now too
//  eager to pass" before committing the per-tier margins.
//
//  This is a process-wide, opt-in counter that `decideBid` writes to only while
//  `isEnabled`. An A/B test resets it, runs a self-play batch with the gate on,
//  and reads `flipRate`. Off by default → zero cost in normal play.
//
//  Thread-safety: decideBid can run off the main actor, so the counters are
//  lock-guarded and the type is @unchecked Sendable.
//

import Foundation

nonisolated final class BidGateStats: @unchecked Sendable {

    static let shared = BidGateStats()

    private let lock = NSLock()
    private var enabled = false
    /// In-window lead-bid decisions (partner + opponent both still live) seen by
    /// gate-enabled agents — the denominator.
    private var opportunities = 0
    /// Of those, how many the margin turned from a bid into a pass — the numerator.
    private var flips = 0

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    /// Start (or stop) counting and clear the tallies.
    func begin(enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
        opportunities = 0
        flips = 0
    }

    /// Record one in-window lead-bid decision; `flipped` is true when the
    /// staying-power margin forced a pass.
    func recordOpportunity(flipped: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        opportunities += 1
        if flipped { flips += 1 }
    }

    /// (flips, opportunities, rate) for a test to print.
    func snapshot() -> (flips: Int, opportunities: Int, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        let rate = opportunities > 0 ? Double(flips) / Double(opportunities) : 0
        return (flips, opportunities, rate)
    }
}
