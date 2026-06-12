//
//  DebugFlags.swift
//  Make-a-Million
//
//  Display and rule toggles, plus the hand-complete reveal surface. These
//  make engine-tracked public state legible without exposing hidden hands
//  during play.
//
//  TWO DISTINCT THINGS, with a deliberate boundary between them:
//
//   • Bid and trick history are PUBLIC (everyone at the table sees/hears
//     them) and ride the redacted PlayerView.
//
//   • HandRevealPanel — every seat's DEALT hand, declarer, trump, contract
//     result. This is HIDDEN information. It does NOT come from PlayerView;
//     it comes from GameState.debugReveal(), a separate path that exists
//     only at handComplete and is never handed to an agent. Gated behind a
//     flag so you can switch it off for honest play. Showing this mid-hand,
//     or routing it through PlayerView, would let the Monte Carlo agent
//     "see" hidden hands when it samples — the one thing the architecture
//     must never allow.
//

import SwiftUI
import Combine

// MARK: - Player-facing game settings

/// House rules and display preferences the player can toggle from the
/// settings panel. Persisted in `UserDefaults` so choices stick across
/// launches, and exposed as a shared `ObservableObject` so both the SwiftUI
/// panel and the engine-facing sessions (which read it when a hand starts)
/// see the same values.
///
/// Two kinds of setting live here, with different reach:
///   • DISPLAY toggles (reveal / bid history / last trick / seat trick history)
///     only change what the local board shows. They are read live by
///     `GameBody` as it renders.
///   • RULE toggles (misdeal, endgame tiebreak) change the game itself and
///     are read once per hand, when the session deals, then frozen onto the
///     `GameState` so a hand can't change rules mid-flight.
@MainActor
final class GameSettings: ObservableObject {

    static let shared = GameSettings()

    // ── Card display ────────────────────────────────────────────────────
    /// Show every seat's dealt hand once the hand is over. Hidden info — off
    /// for honest play. Gates `HandRevealPanel`.
    @Published var revealAllCardsAfterHand: Bool { didSet { persist() } }
    /// Keep the full bid record visible after bidding ends, through the rest
    /// of the hand. During bidding itself the record always shows.
    @Published var showBidHistoryDuringHand: Bool { didSet { persist() } }
    /// Show the most recently completed trick during play.
    @Published var showLastTrick: Bool { didSet { persist() } }
    /// Allow seat chips to open the public tricks taken by that player.
    @Published var showFullTrickHistory: Bool { didSet { persist() } }
    /// Show the revealed widow panel on this device's table.
    @Published var showWidow: Bool { didSet { persist() } }
    /// Show each team's running total for the hand in progress.
    @Published var showLiveScores: Bool { didSet { persist() } }

    // ── Audiovisual ─────────────────────────────────────────────────────
    /// Tiger / Bull / Bear plays burst onto the table with an animation.
    @Published var animalAnimations: Bool { didSet { persist() } }
    /// Subtle table and interface sound effects.
    @Published var soundEffectsEnabled: Bool { didSet { persist() } }
    /// Larger animal cue audio, including the bull stampede music.
    @Published var animalSoundsEnabled: Bool { didSet { persist() } }
    /// Shared gain for all short sound effects and animal cues.
    @Published var soundEffectsVolume: Double { didSet { persist() } }

    // ── Difficulty ──────────────────────────────────────────────────────
    /// How hard the AI opponents play. Read fresh at the start of each hand,
    /// so a change applies on the next deal.
    @Published var aiDifficulty: MonteCarloAgent.Difficulty.Level { didSet { persist() } }

    // ── Optional rules ──────────────────────────────────────────────────
    /// Whether the low-money redeal rule is active.
    @Published var misdealEnabled: Bool { didSet { persist() } }
    /// Money-card total at or below which a hand triggers the redeal.
    @Published var misdealThreshold: Int { didSet { persist() } }
    /// When on, a flagged misdeal is redealt only if all four seats agree.
    @Published var misdealByAgreement: Bool { didSet { persist() } }
    /// "Set opening bid": the auction's first bid is pinned to $175,000.
    @Published var openingBidFixed: Bool { didSet { persist() } }
    /// "Widow reveal": when off, only the high bidder sees the widow.
    @Published var widowPublic: Bool { didSet { persist() } }
    /// "Trump not led until played": no trump leads before trump is broken.
    @Published var trumpMustBeBroken: Bool { didSet { persist() } }
    /// Who wins when both teams finish at or over the million in one hand.
    @Published var endgameTiebreak: EndgameTiebreak { didSet { persist() } }

    // ── Developer ───────────────────────────────────────────────────────
    /// Unlocked by tapping the credits panel five times (Android style).
    /// Gates the developer section: deal seed, AI debug log and options.
    @Published var developerMode: Bool { didSet { persist() } }
    /// Append a full-information trace of every completed hand to a file you
    /// can export for AI review. Reveals hidden hands — debug/tuning only.
    @Published var logHandsToFile: Bool { didSet { persist() } }

    private enum Key {
        static let revealAll      = "settings.revealAllCardsAfterHand"
        static let bidHistory     = "settings.showBidHistoryDuringHand"
        static let lastTrick      = "settings.showLastTrick"
        static let trickHistory   = "settings.showFullTrickHistory"
        static let showWidow      = "settings.showWidow"
        static let liveScores     = "settings.showLiveScores"
        static let animalFX       = "settings.animalAnimations"
        static let soundFX        = "settings.soundEffectsEnabled"
        static let animalSounds   = "settings.animalSoundsEnabled"
        static let soundVolume    = "settings.soundEffectsVolume"
        static let misdealEnabled = "settings.misdealEnabled"
        static let misdealAmount  = "settings.misdealThreshold"
        static let misdealAgree   = "settings.misdealByAgreement"
        static let openingFixed   = "settings.openingBidFixed"
        static let widowPublic    = "settings.widowPublic"
        static let trumpBroken    = "settings.trumpMustBeBroken"
        static let endgame        = "settings.endgameTiebreak"
        static let developerMode  = "settings.developerMode"
        static let logHands       = "settings.logHandsToFile"
        static let aiDifficulty   = "settings.aiDifficulty"
    }

    private init() {
        let d = UserDefaults.standard
        // `object(forKey:) as? Bool` distinguishes "never set" (use default)
        // from a stored `false`, which a plain `bool(forKey:)` would conflate.
        revealAllCardsAfterHand  = d.object(forKey: Key.revealAll) as? Bool ?? false
        showBidHistoryDuringHand = d.object(forKey: Key.bidHistory) as? Bool ?? false
        showLastTrick            = d.object(forKey: Key.lastTrick) as? Bool ?? true
        showFullTrickHistory     = d.object(forKey: Key.trickHistory) as? Bool ?? false
        showWidow                = d.object(forKey: Key.showWidow) as? Bool ?? true
        showLiveScores           = d.object(forKey: Key.liveScores) as? Bool ?? true
        animalAnimations         = d.object(forKey: Key.animalFX) as? Bool ?? true
        soundEffectsEnabled      = d.object(forKey: Key.soundFX) as? Bool ?? true
        animalSoundsEnabled      = d.object(forKey: Key.animalSounds) as? Bool ?? true
        soundEffectsVolume       = d.object(forKey: Key.soundVolume) as? Double ?? 0.72
        misdealEnabled           = d.object(forKey: Key.misdealEnabled) as? Bool ?? true
        misdealThreshold         = d.object(forKey: Key.misdealAmount) as? Int ?? 15_000
        misdealByAgreement       = d.object(forKey: Key.misdealAgree) as? Bool ?? false
        openingBidFixed          = d.object(forKey: Key.openingFixed) as? Bool ?? false
        widowPublic              = d.object(forKey: Key.widowPublic) as? Bool ?? true
        trumpMustBeBroken        = d.object(forKey: Key.trumpBroken) as? Bool ?? false
        endgameTiebreak = (d.string(forKey: Key.endgame)
            .flatMap(EndgameTiebreak.init(rawValue:))) ?? .standard
        developerMode            = d.object(forKey: Key.developerMode) as? Bool ?? false
        logHandsToFile           = d.object(forKey: Key.logHands) as? Bool ?? false
        aiDifficulty = (d.string(forKey: Key.aiDifficulty)
            .flatMap(MonteCarloAgent.Difficulty.Level.init(rawValue:))) ?? .normal
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(revealAllCardsAfterHand,  forKey: Key.revealAll)
        d.set(showBidHistoryDuringHand, forKey: Key.bidHistory)
        d.set(showLastTrick,            forKey: Key.lastTrick)
        d.set(showFullTrickHistory,     forKey: Key.trickHistory)
        d.set(showWidow,                forKey: Key.showWidow)
        d.set(showLiveScores,           forKey: Key.liveScores)
        d.set(animalAnimations,         forKey: Key.animalFX)
        d.set(soundEffectsEnabled,      forKey: Key.soundFX)
        d.set(animalSoundsEnabled,      forKey: Key.animalSounds)
        d.set(soundEffectsVolume,       forKey: Key.soundVolume)
        d.set(misdealEnabled,           forKey: Key.misdealEnabled)
        d.set(misdealThreshold,         forKey: Key.misdealAmount)
        d.set(misdealByAgreement,       forKey: Key.misdealAgree)
        d.set(openingBidFixed,          forKey: Key.openingFixed)
        d.set(widowPublic,              forKey: Key.widowPublic)
        d.set(trumpMustBeBroken,        forKey: Key.trumpBroken)
        d.set(endgameTiebreak.rawValue, forKey: Key.endgame)
        d.set(developerMode,            forKey: Key.developerMode)
        d.set(logHandsToFile,           forKey: Key.logHands)
        d.set(aiDifficulty.rawValue,    forKey: Key.aiDifficulty)
    }

    /// The engine's misdeal configuration built from the current toggles.
    var misdealRule: MisdealRule {
        misdealEnabled ? MisdealRule(enabled: true,
                                     threshold: misdealThreshold,
                                     requiresAgreement: misdealByAgreement)
                       : .disabled
    }

    /// The engine's endgame tiebreak rule (1:1 with the stored choice).
    var endgameRule: EndgameTiebreak { endgameTiebreak }

    /// The remaining optional rules bundled for the engine.
    var houseRules: HouseRules {
        HouseRules(openingBidIsFixed: openingBidFixed,
                   widowIsPublic: widowPublic,
                   trumpMustBeBroken: trumpMustBeBroken)
    }

    /// The tuning profile the bots play with, from the selected strength tier.
    var botDifficulty: MonteCarloAgent.Difficulty { aiDifficulty.profile }
}

// MARK: - Shared seat labels (kept consistent with GameView's convention)

private func seatShort(_ p: PlayerID) -> String {
    ["You", "W", "N", "E"][p.raw]
}
private func seatName(_ p: PlayerID) -> String {
    ["South (You)", "West", "North", "East"][p.raw]
}

// MARK: - End-of-hand hand reveal (hidden info — debug only)

struct HandRevealPanel: View {
    @EnvironmentObject private var settings: GameSettings
    let reveal: DebugReveal?

    var body: some View {
        if settings.revealAllCardsAfterHand, let r = reveal {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack {
                    Text("Hand reveal (debug)")
                        .font(TableTypography.display(.caption, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    contractBadge(r)
                }

                ForEach(Seats.all, id: \.raw) { seat in
                    seatRow(seat, r)
                }

                if !r.dealtWidow.isEmpty {
                    HStack(spacing: 6) {
                        Text("Widow")
                            .font(TableTypography.display(.caption2)).foregroundStyle(.tertiary)
                            .frame(width: 70, alignment: .leading)
                        ForEach(Array(r.dealtWidow.enumerated()), id: \.offset) { _, c in
                            Text(c.shortLabel).font(TableTypography.display(.caption2))
                                .foregroundStyle(c.tint)
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        } else {
            EmptyView()
        }
    }

    private func contractBadge(_ r: DebugReveal) -> some View {
        let made = r.made
        let text: String = {
            guard let c = r.contract, let d = r.declarer else { return "no contract" }
            return "\(seatShort(d)) bid $\(c / 1000)k — "
                 + (made ? "made ($\(r.bidTeamGross / 1000)k)"
                         : "SET ($\(r.bidTeamGross / 1000)k)")
        }()
        return Text(text)
            .font(TableTypography.display(.caption, weight: .bold))
            .foregroundStyle(made ? TableStyle.cardPlayable : TableStyle.teamAmber)
    }

    private func seatRow(_ seat: PlayerID, _ r: DebugReveal) -> some View {
        let hand = (r.dealtHands[seat] ?? [])
            .sorted { handKey($0) > handKey($1) }
        let isDeclarer = (seat == r.declarer)
        return HStack(alignment: .top, spacing: 6) {
            Text(seatShort(seat))
                .font(TableTypography.display(.caption2))
                .fontWeight(isDeclarer ? .bold : .regular)
                .foregroundStyle(isDeclarer ? AnyShapeStyle(.primary)
                                            : AnyShapeStyle(.secondary))
                .frame(width: 70, alignment: .leading)
            FlowRow(spacing: 4) {
                ForEach(Array(hand.enumerated()), id: \.offset) { _, c in
                    Text(c.shortLabel)
                        .font(TableTypography.display(.caption2)).foregroundStyle(c.tint)
                }
            }
        }
    }

    // Local sort key (high → low), independent of GameView's private one.
    private func handKey(_ c: Card) -> Int {
        switch c {
        case .colored(let col, let r): return 100 + col.rawValue * 13 + r.rawValue
        case .tiger: return 90
        case .bull:  return 89
        case .bear:  return 88
        }
    }
}

// MARK: - Settings panel

/// The player-facing rules/display panel. Presented as a sheet; binds
/// directly to the shared `GameSettings`, so toggles take effect the moment
/// they change. Display toggles always apply to the current hand live. The
/// RULE sections (difficulty, optional rules) are frozen onto the `GameState`
/// at deal time, so changing them mid-hand would do nothing surprising — to
/// make that legible, `rulesLocked` disables them while a hand is actually
/// being played. They stay editable from the home screen and between hands,
/// applying to the next deal.
struct SettingsView: View {

    /// What this device controls. A CLIENT only owns its own display — the
    /// host's device owns difficulty and the rules of the table — so the
    /// client sheet hides those sections instead of showing dead controls.
    enum Scope {
        case full
        case clientDisplay
    }

    @ObservedObject var settings: GameSettings
    /// True while a hand is in progress: rule controls are disabled, display
    /// controls remain live. The home-screen entry passes `false`.
    var rulesLocked: Bool = false
    var scope: Scope = .full
    /// Seed of the current hand, shown in the developer section when known.
    var dealSeed: UInt64? = nil
    let onClose: () -> Void

    /// Misdeal threshold is edited in $1,000 steps over a sensible range.
    private let misdealRange = 0...50_000
    private let misdealStep = 1_000

    /// Android-style developer unlock: tap the credits panel this many times.
    private static let developerUnlockTaps = 5
    @State private var creditsTapCount = 0
    @State private var creditsFeedback: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                cardDisplaySection
                audiovisualSection
                if scope == .full {
                    difficultySection
                    optionalRulesSection
                }
                creditsSection
                if settings.developerMode {
                    developerSection
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
            .tint(TableStyle.actionBlue)
        }
    }

    // MARK: Card display

    private var cardDisplaySection: some View {
        Section {
            Toggle("Reveal hands after the hand",
                   isOn: $settings.revealAllCardsAfterHand)
            Toggle("Show bid history",
                   isOn: $settings.showBidHistoryDuringHand)
            Toggle("Show the last trick",
                   isOn: $settings.showLastTrick)
                .accessibilityIdentifier("settings.showLastTrickToggle")
            Toggle("Tap seats to show trick history",
                   isOn: $settings.showFullTrickHistory)
            Toggle("Show the widow",
                   isOn: $settings.showWidow)
            Toggle("Show live scores",
                   isOn: $settings.showLiveScores)
        } header: {
            Text("Card display")
        } footer: {
            Text("These change only what your table shows — they reveal no hidden information to the bots, and apply to the current hand immediately. Revealing hands after the hand shows cards that stay hidden in honest play.")
        }
    }

    // MARK: Audiovisual

    private var audiovisualSection: some View {
        Section {
            Toggle("Animal animations", isOn: $settings.animalAnimations)
            Toggle("Sound effects", isOn: $settings.soundEffectsEnabled)
            Toggle("Animal sounds", isOn: $settings.animalSoundsEnabled)
                .disabled(!settings.soundEffectsEnabled)
            HStack {
                Text("Volume")
                Slider(value: $settings.soundEffectsVolume, in: 0...1)
                Text("\(Int((settings.soundEffectsVolume * 100).rounded()))%")
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!settings.soundEffectsEnabled)
        } header: {
            Text("Audiovisual")
        } footer: {
            Text("Animal animations control the table visuals. Sound effects cover card-table feedback, button selections, and animal cue audio.")
        }
    }

    // MARK: Difficulty (slider over the strength tiers)

    private var difficultyBinding: Binding<Double> {
        Binding(
            get: {
                let levels = MonteCarloAgent.Difficulty.Level.allCases
                return Double(levels.firstIndex(of: settings.aiDifficulty) ?? 1)
            },
            set: {
                let levels = MonteCarloAgent.Difficulty.Level.allCases
                let idx = min(max(Int($0.rounded()), 0), levels.count - 1)
                settings.aiDifficulty = levels[idx]
            })
    }

    private var difficultySection: some View {
        let levels = MonteCarloAgent.Difficulty.Level.allCases
        return Section {
            VStack(spacing: 6) {
                Slider(value: difficultyBinding,
                       in: 0...Double(levels.count - 1),
                       step: 1)
                    .accessibilityIdentifier("settings.aiDifficultySlider")
                    .accessibilityLabel("Opponent difficulty")
                    .accessibilityValue(settings.aiDifficulty.displayName)
                HStack {
                    ForEach(levels) { level in
                        Text(level.displayName)
                            .font(.caption2)
                            .fontWeight(level == settings.aiDifficulty ? .bold : .regular)
                            .foregroundStyle(level == settings.aiDifficulty
                                             ? AnyShapeStyle(TableStyle.actionBlue)
                                             : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity,
                                   alignment: alignment(for: level, in: levels))
                    }
                }
            }
        } header: {
            Text("Difficulty")
        } footer: {
            if rulesLocked {
                lockedHint
            } else {
                Text(settings.aiDifficulty.blurb)
            }
        }
        .disabled(rulesLocked)
    }

    private func alignment(for level: MonteCarloAgent.Difficulty.Level,
                           in levels: [MonteCarloAgent.Difficulty.Level]) -> Alignment {
        if level == levels.first { return .leading }
        if level == levels.last { return .trailing }
        return .center
    }

    // MARK: Optional rules (mirrors the rules document's optional section)

    private var optionalRulesSection: some View {
        Section {
            Toggle("Misdeal rule", isOn: $settings.misdealEnabled)
                .accessibilityIdentifier("settings.misdealToggle")
            if settings.misdealEnabled {
                Picker("Redeal", selection: $settings.misdealByAgreement) {
                    Text("Automatic").tag(false)
                    Text("By table agreement").tag(true)
                }
                Stepper(value: $settings.misdealThreshold,
                        in: misdealRange, step: misdealStep) {
                    HStack {
                        Text("Redeal at or below")
                        Spacer()
                        Text("$\(settings.misdealThreshold / 1000)k")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Toggle("Widow visible to everyone", isOn: $settings.widowPublic)
            Toggle("Trump can't lead until broken", isOn: $settings.trumpMustBeBroken)
            Toggle("Opening bid fixed at $175k", isOn: $settings.openingBidFixed)
            Picker("Both reach $1M", selection: $settings.endgameTiebreak) {
                Text("Bid winner wins").tag(EndgameTiebreak.bidder)
                Text("Highest score wins").tag(EndgameTiebreak.highestScore)
            }
        } header: {
            Text("Optional rules")
        } footer: {
            if rulesLocked {
                lockedHint
            } else {
                Text("House variations from the rule book. A misdeal redeals a hand short on money — automatically, or only when all four players agree. Turning off the widow reveal keeps it private to the high bidder. Changes apply from the next deal.")
            }
        }
        .disabled(rulesLocked)
    }

    // MARK: Credits + Android-style developer unlock

    private var creditsSection: some View {
        Section {
            Button(action: handleCreditsTap) {
                VStack(spacing: 4) {
                    Text("Built with ❤️ by Chance and Carter Larsen")
                        .font(TableTypography.display(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    if let creditsFeedback {
                        Text(creditsFeedback)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.creditsPanel")
        }
    }

    private func handleCreditsTap() {
        guard !settings.developerMode else {
            creditsFeedback = "Developer options are already on."
            return
        }
        creditsTapCount += 1
        let remaining = Self.developerUnlockTaps - creditsTapCount
        if remaining <= 0 {
            settings.developerMode = true
            creditsFeedback = "You are now a developer!"
        } else if creditsTapCount >= 3 {
            creditsFeedback = remaining == 1
                ? "1 tap away from developer options…"
                : "\(remaining) taps away from developer options…"
        }
    }

    // MARK: Developer options (hidden until unlocked)

    private var developerSection: some View {
        Section {
            HStack {
                Text("Current deal seed")
                Spacer()
                Text(dealSeed.map(String.init) ?? "—")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if scope == .full {
                Toggle("Log full hands to a file", isOn: $settings.logHandsToFile)
                if settings.logHandsToFile && HandLog.fileExists {
                    ShareLink("Export hand log", item: HandLog.fileURL)
                    Button("Clear hand log", role: .destructive) {
                        HandLog.clear()
                    }
                }
            }
            Button("Hide developer options") {
                settings.developerMode = false
                creditsTapCount = 0
                creditsFeedback = nil
            }
        } header: {
            Text("Developer")
        } footer: {
            if scope == .full {
                Text("The seed reproduces the current deal. The AI debug log writes a full-information trace of every completed hand — all four hands, the widow, every play, and the money flow — to a file you can share for AI review. Reveals hidden information; for tuning only.")
            } else {
                Text("The seed and AI debug log live on the device hosting the game.")
            }
        }
    }

    /// Shown in place of a rule section's footer while a hand is in progress.
    private var lockedHint: some View {
        Label("Locked while a hand is in progress. Change it from the home screen or between hands.",
              systemImage: "lock.fill")
    }
}
