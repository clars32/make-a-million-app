//
//  GameSession.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/20/26.
//


//
//  GameSession.swift
//  Make-A-Million
//
//  Created by Carter Larsen on 5/19/26.
//


//
//  GameSession.swift
//  Make-a-Million
//
//  Owns one HumanAgent + three MonteCarloAgents and runs a hand via
//  GameRunner on a background task.
//
//  ALSO the PRESENTATION BUFFER. The runner emits the human's redacted view
//  after every move — a fast burst between your turns. This object queues
//  those frames and drains them into `displayView` at a watchable cadence.
//
//  THE GUARDRAIL, restated for this file: the engine NEVER waits on this.
//  The runner is suspended in the human's `chooseMove` waiting for a tap —
//  that is normal think-time it already tolerates by design. Pacing the
//  view changes nothing engine-side. `displayView` only ever advances from
//  the feed; nothing here mutates game state or gates a rule on animation.
//
//  OBSERVATION NOTE (unchanged, still true): `human` is its own
//  ObservableObject; SwiftUI does not propagate through a nested one. The
//  view observes `session.human` DIRECTLY for `pending`, and observes this
//  object for `displayView` / `caughtUp`.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class GameSession: ObservableObject {

    let human: HumanAgent

    /// Final state, set only AFTER the last frame has been shown and a brief
    /// settle has elapsed — so the deciding trick is actually seen.
    @Published private(set) var finished: GameState? = nil
    @Published private(set) var running = false

    /// What the table should render right now: the paced, animated state.
    /// Distinct from `human.pending` (the live decision point). Continuous
    /// for the whole hand — never nil between turns, so the hierarchy and
    /// matchedGeometry identities survive.
    @Published private(set) var displayView: PlayerView? = nil

    /// True when the presentation buffer has caught up to the runner. Used
    /// for the "Watching play…" label between your turns.
    @Published private(set) var caughtUp = true

    /// The seat the human occupies (constructed first in `start`).
    private let spectator = PlayerID(0)

    /// Pacing knobs. Per-move cadence and the end-of-hand settle. These are
    /// the dials to turn if the game feels too slow or too frantic.
    private let frameInterval: Duration = .milliseconds(800)
    private let trickSettleInterval: Duration = .milliseconds(1300)
    private let settleInterval: Duration = .milliseconds(1000)
    private let dealAnimationHoldInterval: Duration = .milliseconds(2050)
    
    // MARK: Match progression

    /// All hands in one match share this base; each hand uses (base + handIndex)
    /// so deals are deterministic across the match without all looking the same.
    private var matchSeedBase: UInt64 = 0
    /// 0 for the first hand of a match, increments by one per hand.
    private var handIndex: UInt64 = 0
    /// Rotates left each completed hand.
    private var currentDealer: PlayerID = PlayerID(0)
    /// Cumulative match score carried into the next hand.
    private var currentCarry: [Int: Int] = [0: 0, 1: 0]

    /// The runner emits much faster than we can pace; without a cap the queue
    /// replays the whole hand at the end. Keep only recent frames.
    private let maxQueuedItems = 12

    // How hard the table plays is chosen by the player in Settings → Opponents
    // and read fresh at the start of each hand (see `runHand`), so a change
    // between hands takes effect on the next deal.

    private enum QueueItem {
        case show(PlayerView)
        case pauseTrickSettle
        /// Tail of the queue when the hand has ended. The drain plays
        /// every preceding frame (notably the last trick's settle) and
        /// only THEN flips `finished`, so the deciding trick is seen.
        case handFinishedMarker(GameState)
    }

    private var queue: [QueueItem] = []
    private var draining = false
    private var holdPresentation = false
    private var pauseBotFramesUntil: ContinuousClock.Instant?
    private var pendingFinal: GameState? = nil
    private var dealPresentationHoldToken: Int = -1

    private var runTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil

    /// When the most recent frame was published, so the drain can space
    /// frames by elapsed time rather than only when the next is buffered.
    private var lastPublishAt: ContinuousClock.Instant? = nil

    init() {
        human = HumanAgent(name: "You")
        human.coordinator = self
    }

    /// Begin a fresh match. Resets dealer rotation, hand index, and carry
    /// score, then kicks off the first hand.
    func startNewMatch(dealSeed: UInt64) {
        guard !running else { return }
        matchSeedBase = dealSeed
        handIndex = 0
        currentDealer = PlayerID(0)
        currentCarry = [0: 0, 1: 0]
        runHand()
    }

    /// Continue an in-progress match into the next hand. Carries the
    /// previous hand's match score forward and rotates the dealer left.
    /// No-op if a hand is still running or the match is already decided.
    func startNextHand() {
        guard !running,
              let final = finished,
              final.matchWinner == nil
        else { return }
        currentCarry = final.matchScore
        currentDealer = Seats.next(currentDealer)
        handIndex &+= 1
        runHand()
    }

    /// Launch one hand with the current match-progression state. Shared by
    /// both entry points so dealer/seed/carry handling lives in exactly one
    /// place.
    private func runHand() {
        guard !running else { return }
        running = true
        finished = nil
        displayView = nil
        caughtUp = true
        queue.removeAll()
        draining = false
        holdPresentation = false
        pauseBotFramesUntil = nil
        pendingFinal = nil
        dealPresentationHoldToken = -1

        // Hand-unique seed derived from the match base. Agents seed off it
        // too so their RNGs vary hand to hand (otherwise West would always
        // make the same "random" jump-bid decisions).
        // Arm the AI decision trace for this hand iff file logging is on. This
        // resets the per-hand buffer and gates whether the bots record their
        // reasoning at all (no cost when off — normal play and self-play).
        AIDecisionTrace.shared.beginHand(enabled: GameSettings.shared.logHandsToFile)

        let handSeed = matchSeedBase &+ handIndex
        // Read the chosen strength tier fresh each hand (locked during play, so
        // a change only lands on the next deal).
        let botDifficulty = GameSettings.shared.botDifficulty
        let agents: [PlayerAgent] = [
            human,
            MonteCarloAgent(name: "West",  difficulty: botDifficulty,
                            seed: handSeed &+ 101),
            MonteCarloAgent(name: "North", difficulty: botDifficulty,
                            seed: handSeed &+ 202),
            MonteCarloAgent(name: "East",  difficulty: botDifficulty,
                            seed: handSeed &+ 303),
        ]
        let runner = GameRunner(agents: agents)
        let spectator = self.spectator
        let dealer = currentDealer
        let carry = currentCarry
        // Snapshot the house rules at deal time so a mid-hand settings change
        // can't alter the hand in progress.
        let misdealRule = GameSettings.shared.misdealRule
        let endgameRule = GameSettings.shared.endgameRule

        runTask = Task {
            do {
                let final = try await runner.playHand(
                    dealer: dealer,
                    dealSeed: handSeed,
                    carryScore: carry,
                    misdealRule: misdealRule,
                    endgameRule: endgameRule,
                    spectator: spectator,
                    onView: { [weak self] view in
                        await self?.receivePublicFrameAndHoldForDealIfNeeded(view)
                    })
                await MainActor.run {
                    self.finishHand(final)
                }
            } catch {
                await MainActor.run { self.running = false }
                assertionFailure("GameRunner threw: \(error)")
            }
        }
    }

    func reset() {
        runTask?.cancel();   runTask = nil
        drainTask?.cancel(); drainTask = nil
        queue.removeAll()
        draining = false
        holdPresentation = false
        pauseBotFramesUntil = nil
        pendingFinal = nil
        dealPresentationHoldToken = -1
        displayView = nil
        finished = nil
        running = false
        caughtUp = true
        // Match-progression state — wipe so the next start is a fresh match.
        matchSeedBase = 0
        handIndex = 0
        currentDealer = PlayerID(0)
        currentCarry = [0: 0, 1: 0]
    }

    /// Reset only the presentation buffer for a NetSession-driven next hand —
    /// clears the end-of-hand panel and queued frames so the new deal renders
    /// cleanly. Unlike `reset()`, this leaves match-progression state alone
    /// (the networked flow owns dealer/score on NetSession, not here).
    func beginNetHand() {
        drainTask?.cancel(); drainTask = nil
        queue.removeAll()
        draining = false
        holdPresentation = false
        pauseBotFramesUntil = nil
        pendingFinal = nil
        dealPresentationHoldToken = -1
        lastPublishAt = nil
        displayView = nil
        finished = nil
        running = false
        caughtUp = true
    }

    // MARK: - Buffer

    /// Awaited by GameRunner so frames are queued before the next agent acts.
    /// Also called by NetSession's host-session bridge when the engine
    /// lives on NetSession instead of inside GameSession itself.
    func receivePublicFrame(_ view: PlayerView) {
        if isRedundantWithDisplay(view) { return }

        if let live = effectiveTableView(),
           trickJustCompleted(comparedTo: live, incoming: view) {
            enqueueTrickSettle(from: live, resolved: view)
            return
        }

        enqueue(.show(view))
    }

    /// Publish the frame immediately, then hold the runner on the initial
    /// deal frame so bots do not begin bidding until the deal animation has
    /// had time to complete.
    private func receivePublicFrameAndHoldForDealIfNeeded(_ view: PlayerView) async {
        let shouldHold = shouldHoldForDealAnimation(view)
        receivePublicFrame(view)
        if shouldHold {
            try? await Task.sleep(for: dealAnimationHoldInterval)
        }
    }

    private func shouldHoldForDealAnimation(_ view: PlayerView) -> Bool {
        let token = dealAnimationToken(for: view)
        guard token >= 0, token != dealPresentationHoldToken else { return false }
        dealPresentationHoldToken = token
        return true
    }

    /// Latest table snapshot: last queued show, else what is on screen.
    private func effectiveTableView() -> PlayerView? {
        for item in queue.reversed() {
            if case .show(let view) = item { return view }
        }
        return displayView
    }

    private func trickJustCompleted(comparedTo live: PlayerView,
                                    incoming: PlayerView) -> Bool {
        incoming.completedTricks.count == live.completedTricks.count + 1
            && incoming.lastTrick?.plays.count == Seats.count
    }

    /// Fourth card (if needed) → pause → cleared trick. Never rewinds completed tricks.
    private func enqueueTrickSettle(from live: PlayerView, resolved: PlayerView) {
        if live.currentTrick?.plays.count == Seats.count {
            // Human preview (or table) already shows the full trick.
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else if let fourth = live.addingLastPlay(from: resolved) {
            enqueue(.show(fourth))
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else if let hold = trickCompletionHoldFrame(before: resolved, live: live) {
            enqueue(.show(hold))
            enqueue(.pauseTrickSettle)
            enqueue(.show(resolved))
        } else {
            enqueue(.show(resolved))
        }
    }

    /// Fallback when we did not see the third play before resolution.
    private func trickCompletionHoldFrame(before resolved: PlayerView,
                                          live: PlayerView) -> PlayerView? {
        guard let finished = resolved.lastTrick else { return nil }
        return PlayerView(
            me: resolved.me,
            myHand: resolved.myHand,
            phase: resolved.phase,
            toAct: resolved.toAct,
            trump: resolved.trump,
            highBid: resolved.highBid,
            highBidder: resolved.highBidder,
            passed: resolved.passed,
            opener: resolved.opener,
            bidHistory: resolved.bidHistory,
            widow: resolved.widow,
            currentTrick: Trick(leader: finished.leader, plays: finished.plays),
            completedTrickCount: live.completedTricks.count,
            completedTricks: live.completedTricks,
            matchScore: resolved.matchScore,
            legalMoves: []
        )
    }

    private func isRedundantWithDisplay(_ view: PlayerView) -> Bool {
        guard let live = displayView else { return false }
        return live.phase == view.phase
            && live.myHand.count == view.myHand.count
            && live.currentTrick?.plays.count == view.currentTrick?.plays.count
            && live.completedTricks.count == view.completedTricks.count
            && live.bidHistory.count == view.bidHistory.count
    }

    private func enqueue(_ item: QueueItem) {
        queue.append(item)
        trimQueue()
        if holdPresentation {
            caughtUp = false
            return
        }
        caughtUp = false
        startDrainIfNeeded()
    }

    private func trimQueue() {
        while queue.count > maxQueuedItems {
            if let idx = queue.firstIndex(where: {
                if case .show = $0 { return true }
                return false
            }) {
                queue.remove(at: idx)
            } else {
                queue.removeFirst()
            }
        }
    }

    private func publishFrame(_ view: PlayerView) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
            displayView = view
        }
        lastPublishAt = ContinuousClock.now
    }

    /// Sleep until at least `frameInterval` has elapsed since the last
    /// published frame. This paces frames that trickle in one at a time
    /// (e.g. a remote host streaming bot plays) the same as a buffered burst.
    private func paceSinceLastFrame() async {
        guard let last = lastPublishAt else { return }
        let target = last + frameInterval
        let clock = ContinuousClock()
        if clock.now < target { try? await clock.sleep(until: target) }
    }

    /// After the human previews a card, hold before the first bot frame even
    /// if that frame is drained through the "catch up before my turn" path.
    private func waitForPostHumanPreviewIfNeeded() async {
        guard let until = pauseBotFramesUntil else { return }
        let clock = ContinuousClock()
        if clock.now < until {
            try? await clock.sleep(until: until)
        }
        pauseBotFramesUntil = nil
    }

    /// Mark the hand finished and transition the UI through the end-of-
    /// hand settle. Called locally by GameSession's own runner in the
    /// solo flow, and called externally by NetSession's bridge when the
    /// engine lives on NetSession (host networked flow).
    ///
    /// Do NOT clear the queue or publish the final view here. The last
    /// trick's settle frames (4th-card show + pause + resolved frame)
    /// were enqueued by `receivePublicFrame` an instant before this call
    /// and MUST play out — otherwise the player never sees who took the
    /// deciding trick. We append a marker; the drain processes it last
    /// and flips `finished` then.
    func finishHand(_ final: GameState) {
        // Debug capture: a full-information trace for AI review. Off by default;
        // reveals hidden hands, so it's for tuning only. Rendered from the
        // final state (no engine plumbing, nothing leaks mid-hand).
        if GameSettings.shared.logHandsToFile, final.phase == .handComplete {
            let labels = ["South (You · human)", "West (AI)", "North (AI)", "East (AI)"]
            let log = HandLog.render(final, handIndex: Int(handIndex), seatLabels: labels,
                                     decisions: AIDecisionTrace.shared.snapshot())
            HandLog.append(log)
            print(log)
        }
        pendingFinal = final
        enqueue(.handFinishedMarker(final))
    }

    private func startDrainIfNeeded() {
        guard !holdPresentation else { return }
        guard !draining else { return }
        guard !queue.isEmpty else { return }
        draining = true

        drainTask = Task { @MainActor in
            while !queue.isEmpty && !holdPresentation {
                if Task.isCancelled { return }
                await waitForPostHumanPreviewIfNeeded()
                // The sleep above suspended the main actor. finishHand,
                // reset, or another start can have run during the gap
                // and emptied the queue. Re-check before we touch it.
                if Task.isCancelled { return }
                if queue.isEmpty || holdPresentation { break }

                // Belt-and-braces guard — any future await above this line
                // could also empty the queue, so make removeFirst() honest.
                guard !queue.isEmpty else { break }
                switch queue.removeFirst() {
                case .show(let view):
                    // Pace before showing, so frames are evenly spaced whether
                    // they were buffered or arrived one at a time.
                    await paceSinceLastFrame()
                    if Task.isCancelled { return }
                    publishFrame(view)
                case .pauseTrickSettle:
                    try? await Task.sleep(for: trickSettleInterval)
                case .handFinishedMarker(let final):
                    // Hold on the cleared/resolved last-trick frame so
                    // the lastTrick panel registers, then flip to the
                    // end-of-hand panel. `pendingFinal` guards against
                    // reset() racing during the sleep.
                    try? await Task.sleep(for: settleInterval)
                    if Task.isCancelled { return }
                    if self.pendingFinal != nil {
                        publishFrame(final.view(for: spectator))
                        self.finished = final
                        self.running = false
                    }
                }
            }

            draining = false
            caughtUp = queue.isEmpty && !holdPresentation

            if !holdPresentation && !queue.isEmpty {
                startDrainIfNeeded()
            }
        }
    }

    private func drainQueueOnMainActor() async {
        while !queue.isEmpty {
            await waitForPostHumanPreviewIfNeeded()
            await paceSinceLastFrame()

            guard !queue.isEmpty else { break }
            switch queue.removeFirst() {
            case .show(let view):
                publishFrame(view)
            case .pauseTrickSettle:
                try? await Task.sleep(for: trickSettleInterval)
            case .handFinishedMarker(let final):
                try? await Task.sleep(for: settleInterval)
                if self.pendingFinal != nil {
                    publishFrame(final.view(for: spectator))
                    self.finished = final
                    self.running = false
                }
            }
        }
    }
}

// MARK: - Human turn pacing (PresentationCoordinator)

extension GameSession: PresentationCoordinator {

    /// Play every queued bot frame at full cadence, then hand off to the human.
    func drainBeforeHumanTurn() async {
        drainTask?.cancel()
        draining = false
        await drainQueueOnMainActor()
        caughtUp = true
    }

    func humanTurnDidBegin() {
        holdPresentation = true
        drainTask?.cancel()
        draining = false
    }

    func humanCommittedMove(_ move: Move, from view: PlayerView) {
        guard let preview = view.previewing(move) else { return }
        drainTask?.cancel()
        draining = false
        publishFrame(preview)
        pauseBotFramesUntil = ContinuousClock.now + frameInterval
        caughtUp = false
    }

    func humanTurnDidEnd() {
        holdPresentation = false
        caughtUp = queue.isEmpty && pauseBotFramesUntil == nil
        startDrainIfNeeded()
    }
}
