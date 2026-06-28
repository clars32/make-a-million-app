//
//  GameSession.swift
//  Make-a-Million
//
//  Created by Carter Larsen on 5/19/26.
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

    /// Seed of the hand currently being played (or just finished) — surfaced
    /// by the developer section of the settings panel.
    @Published private(set) var currentHandSeed: UInt64? = nil

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

    // MARK: Resume / autosave

    /// The single resumable-solo-match slot. Written after every move so the
    /// game can be resumed to the exact card; cleared when the match is decided.
    private let store = SoloGameStore.shared
    /// Move log of the hand in progress, persisted after every move. Reset at
    /// the start of each hand; pre-seeded from the save when resuming.
    private var recordedMoves: [RecordedMove] = []
    /// Rules frozen onto the current hand at deal time, saved alongside the log
    /// so a resume replays under identical legality. Set in `runHand`.
    private var currentMisdealRule: MisdealRule = .standard
    private var currentEndgameRule: EndgameTiebreak = .standard
    private var currentHouseRules: HouseRules = .standard
    /// Set by `resume(from:)` and consumed by the next `runHand`: the saved log
    /// to replay plus the rules to deal/continue the current hand under. nil
    /// for a fresh hand.
    private var pendingResume: (moves: [RecordedMove],
                                misdealRule: MisdealRule,
                                endgameRule: EndgameTiebreak,
                                houseRules: HouseRules)? = nil
    /// True only for a GameSession that drives the SOLO flow, so the shared
    /// solo save is owned by exactly one instance. The networked-host bridge
    /// (which reuses this object only as a presentation buffer) leaves it false
    /// and never reads, writes, or clears the slot.
    private var managesSoloSave = false

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
    private var animalCuePauseTracker = AnimalCuePauseTracker()

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
    /// score, then kicks off the first hand. Takes ownership of the solo save
    /// slot — the first deal overwrites whatever was there.
    func startNewMatch(dealSeed: UInt64) {
        guard !running else { return }
        managesSoloSave = true
        pendingResume = nil
        matchSeedBase = dealSeed
        handIndex = 0
        currentDealer = PlayerID(0)
        currentCarry = [0: 0, 1: 0]
        runHand()
    }

    /// Resume a previously saved solo match exactly where it was left.
    /// Restores match progression and the current hand's frozen rules + move
    /// log, then re-deals and silently replays to that position before handing
    /// control back. No-op if a hand is already running.
    func resume(from saved: SavedSoloGame) {
        guard !running else { return }
        managesSoloSave = true
        matchSeedBase = saved.matchSeedBase
        handIndex = saved.handIndex
        currentDealer = saved.dealer
        currentCarry = saved.carry
        pendingResume = (moves: saved.moves,
                         misdealRule: saved.misdealRule,
                         endgameRule: saved.endgameRule,
                         houseRules: saved.houseRules)
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
        animalCuePauseTracker.reset()

        // Hand-unique seed derived from the match base. Agents seed off it
        // too so their RNGs vary hand to hand (otherwise West would always
        // make the same "random" jump-bid decisions).
        // Arm the AI decision trace for this hand iff file logging is on. This
        // resets the per-hand buffer and gates whether the bots record their
        // reasoning at all (no cost when off — normal play and self-play).
        AIDecisionTrace.shared.beginHand(enabled: GameSettings.shared.logHandsToFile)

        let handSeed = matchSeedBase &+ handIndex
        currentHandSeed = handSeed
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

        // Resuming replays a saved log under the SAME rules the hand was dealt
        // with; a fresh hand snapshots the current settings so a mid-hand
        // settings change can't alter the hand in progress. Either way the
        // rules used are remembered so the log saved this hand carries them.
        let resume = pendingResume
        pendingResume = nil
        let misdealRule = resume?.misdealRule ?? GameSettings.shared.misdealRule
        let endgameRule = resume?.endgameRule ?? GameSettings.shared.endgameRule
        let houseRules  = resume?.houseRules  ?? GameSettings.shared.houseRules
        currentMisdealRule = misdealRule
        currentEndgameRule = endgameRule
        currentHouseRules  = houseRules

        // Start (or restore) the move log for this hand and persist immediately,
        // so even a hand resumed-then-backgrounded before any new move is saved.
        recordedMoves = resume?.moves ?? []
        persistSavedGame()

        let onView: @Sendable @MainActor (PlayerView) async -> Void = { [weak self] view in
            await self?.receivePublicFrameAndHoldForDealIfNeeded(view)
        }
        let onMove: @Sendable @MainActor (RecordedMove) async -> Void = { [weak self] move in
            self?.recordAppliedMove(move)
        }

        runTask = Task {
            do {
                let final: GameState
                if let resume {
                    final = try await runner.resumeHand(
                        dealer: dealer,
                        dealSeed: handSeed,
                        carryScore: carry,
                        misdealRule: misdealRule,
                        endgameRule: endgameRule,
                        houseRules: houseRules,
                        moves: resume.moves,
                        spectator: spectator,
                        onView: onView,
                        onMove: onMove)
                } else {
                    final = try await runner.playHand(
                        dealer: dealer,
                        dealSeed: handSeed,
                        carryScore: carry,
                        misdealRule: misdealRule,
                        endgameRule: endgameRule,
                        houseRules: houseRules,
                        spectator: spectator,
                        onView: onView,
                        onMove: onMove)
                }
                await MainActor.run {
                    self.finishHand(final)
                }
            } catch {
                await MainActor.run { self.running = false }
                assertionFailure("GameRunner threw: \(error)")
            }
        }
    }

    /// Append an applied move to the live log and persist the snapshot. Called
    /// from the runner's `onMove` sink for every move past the resumed point.
    private func recordAppliedMove(_ move: RecordedMove) {
        recordedMoves.append(move)
        persistSavedGame()
    }

    /// Write the current hand's resumable snapshot. No-op for a session that
    /// does not own the solo slot (the networked-host presentation bridge).
    private func persistSavedGame() {
        guard managesSoloSave else { return }
        store.save(SavedSoloGame(
            matchSeedBase: matchSeedBase,
            handIndex: handIndex,
            dealer: currentDealer,
            carry: currentCarry,
            misdealRule: currentMisdealRule,
            endgameRule: currentEndgameRule,
            houseRules: currentHouseRules,
            moves: recordedMoves,
            savedAt: Date()))
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
        animalCuePauseTracker.reset()
        displayView = nil
        finished = nil
        running = false
        caughtUp = true
        currentHandSeed = nil
        // Match-progression state — wipe so the next start is a fresh match.
        matchSeedBase = 0
        handIndex = 0
        currentDealer = PlayerID(0)
        currentCarry = [0: 0, 1: 0]
        // Resume state — the next start (startNewMatch) takes the slot afresh.
        recordedMoves = []
        pendingResume = nil
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
        animalCuePauseTracker.reset()
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
        await pauseForAnimalCueIfNeeded(after: view)
    }

    private func shouldHoldForDealAnimation(_ view: PlayerView) -> Bool {
        let token = dealAnimationToken(for: view)
        guard token >= 0, token != dealPresentationHoldToken else { return false }
        dealPresentationHoldToken = token
        return true
    }

    private func pauseForAnimalCueIfNeeded(after view: PlayerView) async {
        guard let duration = animalCuePauseTracker.holdDuration(
            after: view,
            animationsEnabled: GameSettings.shared.animalAnimations)
        else { return }

        try? await Task.sleep(for: duration)
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
            discardAnnouncement: resolved.discardAnnouncement,
            houseRules: resolved.houseRules,
            currentTrick: Trick(leader: finished.leader, plays: finished.plays),
            completedTrickCount: live.completedTricks.count,
            completedTricks: live.completedTricks,
            matchScore: resolved.matchScore,
            legalMoves: []
        )
    }

    private func isRedundantWithDisplay(_ view: PlayerView) -> Bool {
        guard let live = displayView else { return false }
        // Compare hand CONTENTS, not just count: a redeal into another short
        // hand (agreement-mode misdeal vote, or a double auto-misdeal) keeps
        // the phase and every count identical while replacing all the cards.
        return live.phase == view.phase
            && live.myHand == view.myHand
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
        #if DEBUG
        warnOnMultiStepAdvance(to: view)
        #endif
        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
            displayView = view
        }
        lastPublishAt = ContinuousClock.now
    }

    #if DEBUG
    /// Tripwire for the lost-frame class of bug. During trick play the table
    /// should advance exactly one card per published frame; trick-settle frames
    /// (4th card shown, then the cleared trick) keep the count flat, so they
    /// don't trip this. A jump of more than one card means a frame was swallowed
    /// — the cards will animate in together under a single sound cue.
    private func warnOnMultiStepAdvance(to view: PlayerView) {
        guard let old = displayView,
              old.phase == .trickPlay, view.phase == .trickPlay else { return }
        let delta = view.cardsPlayedCount - old.cardsPlayedCount
        if delta > 1 {
            print("⚠️ presentation: displayView advanced \(delta) plays in one "
                  + "frame (\(old.cardsPlayedCount) → \(view.cardsPlayedCount)) — "
                  + "a frame was dropped; cards will animate together")
        }
    }
    #endif

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
        // Resume bookkeeping: a decided match has nothing left to resume, so
        // drop the slot. A match that continues keeps the just-finished hand
        // saved (resuming lands on the end-of-hand scorecard) until "Deal
        // another" rewrites the log for the next hand via startNextHand.
        if managesSoloSave, final.matchWinner != nil {
            store.clear()
        }
        pendingFinal = final
        enqueue(.handFinishedMarker(final))
    }

    /// Process one dequeued presentation item. Shared by both drain paths
    /// (the background `startDrainIfNeeded` loop and the synchronous
    /// `drainQueueOnMainActor` used before the human's turn) so the per-item
    /// handling lives in exactly one place and can't drift between them.
    private func handleDequeued(_ item: QueueItem) async {
        switch item {
        case .show(let view):
            publishFrame(view)
        case .pauseTrickSettle:
            try? await Task.sleep(for: trickSettleInterval)
        case .handFinishedMarker(let final):
            // Hold on the cleared/resolved last-trick frame so the lastTrick
            // panel registers, then flip to the end-of-hand panel.
            // `pendingFinal` guards against reset() racing during the sleep.
            try? await Task.sleep(for: settleInterval)
            if Task.isCancelled { return }
            if self.pendingFinal != nil {
                publishFrame(final.view(for: spectator))
                self.finished = final
                self.running = false
            }
        }
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

                // Pace a frame BEFORE it leaves the queue. If we dequeued first
                // and were then cancelled during the pacing sleep, the frame
                // would be lost — gone from the queue, never published —
                // leaving the table a move behind exactly at the human's turn
                // (where drainBeforeHumanTurn does the cancel). Peeking keeps
                // the frame in the queue across the await, so a cancel hands it
                // intact to drainQueueOnMainActor instead of swallowing it.
                if case .show = queue.first {
                    await paceSinceLastFrame()
                    if Task.isCancelled { return }
                    if queue.isEmpty || holdPresentation { break }
                }

                // Belt-and-braces guard — any await above this line could also
                // empty the queue, so make removeFirst() honest.
                guard !queue.isEmpty else { break }
                await handleDequeued(queue.removeFirst())
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
            await handleDequeued(queue.removeFirst())
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

#if DEBUG
private extension PlayerView {
    /// Cards played in the hand so far: completed tricks plus the in-progress
    /// trick. Advances by exactly one per card play and stays flat as a trick
    /// resolves (the 4th card moves from `currentTrick` into `completedTricks`
    /// for a net of zero), so a publish that advances it by more than one means
    /// a frame was dropped. Used by the presentation tripwire only.
    var cardsPlayedCount: Int {
        completedTricks.count * Seats.count + (currentTrick?.plays.count ?? 0)
    }
}
#endif
