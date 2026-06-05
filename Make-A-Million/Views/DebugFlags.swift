//
//  DebugFlags.swift
//  Make-a-Million
//
//  The bidding-visibility pass, view side. Same intent as the trick-history
//  panel you already built: make the state the engine tracks LEGIBLE so
//  bidding can be judged instead of guessed at. Deliberately plain.
//
//  TWO DISTINCT THINGS, with a deliberate boundary between them:
//
//   • The bid SEQUENCE is PUBLIC (everyone at the table hears it) and is
//     presented by GameView.bidHistoryPanel, riding the redacted PlayerView
//     (view.bidHistory) exactly like completed tricks do.
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
///   • DISPLAY toggles (reveal / bid history / last trick / trick history)
///     only change what the local board shows. They are read live by
///     `GameBody` as it renders.
///   • RULE toggles (misdeal, endgame tiebreak) change the game itself and
///     are read once per hand, when the session deals, then frozen onto the
///     `GameState` so a hand can't change rules mid-flight.
@MainActor
final class GameSettings: ObservableObject {

    static let shared = GameSettings()

    /// Show every seat's dealt hand once the hand is over. Hidden info — off
    /// for honest play. Gates `HandRevealPanel`.
    @Published var revealAllCardsAfterHand: Bool { didSet { persist() } }
    /// Keep the full bid record visible after bidding ends, through the rest
    /// of the hand. During bidding itself the panel always shows.
    @Published var showBidHistoryDuringHand: Bool { didSet { persist() } }
    /// Show the most recently completed trick during play.
    @Published var showLastTrick: Bool { didSet { persist() } }
    /// Show the full, scrollable trick history during play.
    @Published var showFullTrickHistory: Bool { didSet { persist() } }
    /// Whether the automatic low-money redeal rule is active.
    @Published var misdealEnabled: Bool { didSet { persist() } }
    /// Money-card total at or below which a hand triggers the redeal.
    @Published var misdealThreshold: Int { didSet { persist() } }
    /// Who wins when both teams finish at or over the million in one hand.
    @Published var endgameTiebreak: EndgameTiebreak { didSet { persist() } }
    /// Append a full-information trace of every completed hand to a file you
    /// can export for AI review. Reveals hidden hands — debug/tuning only.
    @Published var logHandsToFile: Bool { didSet { persist() } }

    private enum Key {
        static let revealAll      = "settings.revealAllCardsAfterHand"
        static let bidHistory     = "settings.showBidHistoryDuringHand"
        static let lastTrick      = "settings.showLastTrick"
        static let trickHistory   = "settings.showFullTrickHistory"
        static let misdealEnabled = "settings.misdealEnabled"
        static let misdealAmount  = "settings.misdealThreshold"
        static let endgame        = "settings.endgameTiebreak"
        static let logHands       = "settings.logHandsToFile"
    }

    private init() {
        let d = UserDefaults.standard
        // `object(forKey:) as? Bool` distinguishes "never set" (use default)
        // from a stored `false`, which a plain `bool(forKey:)` would conflate.
        revealAllCardsAfterHand  = d.object(forKey: Key.revealAll) as? Bool ?? false
        showBidHistoryDuringHand = d.object(forKey: Key.bidHistory) as? Bool ?? false
        showLastTrick            = d.object(forKey: Key.lastTrick) as? Bool ?? true
        showFullTrickHistory     = d.object(forKey: Key.trickHistory) as? Bool ?? false
        misdealEnabled           = d.object(forKey: Key.misdealEnabled) as? Bool ?? true
        misdealThreshold         = d.object(forKey: Key.misdealAmount) as? Int ?? 15_000
        endgameTiebreak = (d.string(forKey: Key.endgame)
            .flatMap(EndgameTiebreak.init(rawValue:))) ?? .standard
        logHandsToFile           = d.object(forKey: Key.logHands) as? Bool ?? false
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(revealAllCardsAfterHand,  forKey: Key.revealAll)
        d.set(showBidHistoryDuringHand, forKey: Key.bidHistory)
        d.set(showLastTrick,            forKey: Key.lastTrick)
        d.set(showFullTrickHistory,     forKey: Key.trickHistory)
        d.set(misdealEnabled,           forKey: Key.misdealEnabled)
        d.set(misdealThreshold,         forKey: Key.misdealAmount)
        d.set(endgameTiebreak.rawValue, forKey: Key.endgame)
        d.set(logHandsToFile,           forKey: Key.logHands)
    }

    /// The engine's misdeal configuration built from the current toggles.
    var misdealRule: MisdealRule {
        misdealEnabled ? MisdealRule(enabled: true, threshold: misdealThreshold)
                       : .disabled
    }

    /// The engine's endgame tiebreak rule (1:1 with the stored choice).
    var endgameRule: EndgameTiebreak { endgameTiebreak }
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
/// RULE sections (misdeal, endgame) are frozen onto the `GameState` at deal
/// time, so changing them mid-hand would do nothing surprising — to make that
/// legible, `rulesLocked` disables them while a hand is actually being played.
/// They stay editable from the home screen and between hands, applying to the
/// next deal.
struct SettingsView: View {
    @ObservedObject var settings: GameSettings
    /// True while a hand is in progress: rule controls are disabled, display
    /// controls remain live. The home-screen entry passes `false`.
    var rulesLocked: Bool = false
    /// Optional solo match seed, shown only by the solo in-game settings sheet.
    var dealSeed: UInt64? = nil
    let onClose: () -> Void

    /// Misdeal threshold is edited in $1,000 steps over a sensible range.
    private let misdealRange = 0...50_000
    private let misdealStep = 1_000

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Reveal all hands after the hand",
                           isOn: $settings.revealAllCardsAfterHand)
                    Toggle("Show full bid history during the hand",
                           isOn: $settings.showBidHistoryDuringHand)
                    Toggle("Show the last trick during the hand",
                           isOn: $settings.showLastTrick)
                        .accessibilityIdentifier("settings.showLastTrickToggle")
                    Toggle("Show full trick history during the hand",
                           isOn: $settings.showFullTrickHistory)
                } header: {
                    Text("Display")
                } footer: {
                    Text("These change only what your table shows — they reveal no hidden information to the bots, and apply to the current hand immediately.")
                }

                if let dealSeed {
                    Section {
                        HStack {
                            Text("Match seed")
                            Spacer()
                            Text(String(dealSeed))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("Solo")
                    } footer: {
                        Text("This seed identifies the current solo match and can be used to reproduce the deal sequence.")
                    }
                }

                Section {
                    Toggle("Misdeal rule", isOn: $settings.misdealEnabled)
                        .accessibilityIdentifier("settings.misdealToggle")
                    if settings.misdealEnabled {
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
                } header: {
                    Text("Misdeal")
                } footer: {
                    if rulesLocked {
                        lockedHint
                    } else {
                        Text("When on, a hand whose money-card total falls at or below the threshold is automatically redealt.")
                    }
                }
                .disabled(rulesLocked)

                Section {
                    Picker("Both reach $1M", selection: $settings.endgameTiebreak) {
                        Text("Bid winner wins").tag(EndgameTiebreak.bidder)
                        Text("Highest score wins").tag(EndgameTiebreak.highestScore)
                    }
                } header: {
                    Text("Endgame")
                } footer: {
                    if rulesLocked {
                        lockedHint
                    } else {
                        Text("If both teams cross a million in the same hand, this decides the match.")
                    }
                }
                .disabled(rulesLocked)

                Section {
                    Toggle("Log full hands to a file", isOn: $settings.logHandsToFile)
                    if settings.logHandsToFile && HandLog.fileExists {
                        ShareLink("Export hand log", item: HandLog.fileURL)
                        Button("Clear hand log", role: .destructive) {
                            HandLog.clear()
                        }
                    }
                } header: {
                    Text("AI debug log")
                } footer: {
                    Text("Writes a full-information trace of every completed hand — all four hands, the widow, every play, and the money flow — to a file you can share for AI review. Reveals hidden information; for tuning only.")
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

    /// Shown in place of a rule section's footer while a hand is in progress.
    private var lockedHint: some View {
        Label("Locked while a hand is in progress. Change it from the home screen or between hands.",
              systemImage: "lock.fill")
    }
}
