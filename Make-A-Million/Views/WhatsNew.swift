//
//  WhatsNew.swift
//  Make-a-Million
//
//  The "What's New" update pop-up: a short changelog that appears on the
//  first launch after the player updates the app, plus a manual entry point
//  from Settings that shows the full history.
//
//  HOW THE "ON UPDATE" TRIGGER WORKS:
//
//   • The trigger keys on an internal, monotonic `seq` per entry — NOT on the
//     bundle build number. The build number is the git commit count, set at
//     build time (see RELEASING.md), so you can't pin it when writing the code;
//     `seq` is the stable thing to gate on.
//   • `WhatsNewGate` remembers the highest `seq` the player has seen, in
//     UserDefaults:
//       – No stored seq → fresh install. Record the latest silently, show
//         nothing (new players shouldn't get a changelog on day one).
//       – Unseen entries exist (seq > stored) → show them.
//       – Otherwise → nothing.
//   • The stored seq advances only when the player dismisses the pop-up, so
//     killing the app mid-read shows it again.
//
//  MAINTAINING THE CHANGELOG: each release, prepend a `ReleaseNote` with a
//  `seq` one greater than the current top entry. That alone makes the pop-up
//  appear for everyone who updates. `version` is the marketing version (semver,
//  matching the git tag, e.g. "0.9.1") — set it to whatever you bump
//  MARKETING_VERSION to. Build numbers aren't listed per entry: Xcode Cloud
//  owns them and they don't track the version history. Entries are curated from
//  the project's commit history — user-facing changes, phrased for players.
//  See RELEASING.md for the full release flow.
//

import SwiftUI

// MARK: - Changelog data

/// One announced release and the player-facing summary of what changed in it.
struct ReleaseNote: Identifiable {
    /// Internal monotonic order key. Drives the "what's new since last launch"
    /// trigger. Higher = newer. Independent of the bundle build number.
    let seq: Int
    /// The marketing version (semver, matching the git tag), e.g. "0.9.1".
    /// This is the identifier — build numbers are owned by Xcode Cloud and not
    /// listed per entry (they don't match the version history).
    let version: String
    /// Display date the release shipped, e.g. "Jun 27, 2026".
    let date: String
    /// Short headline for the entry.
    let title: String
    /// The corresponding commit message, phrased for players.
    let summary: String

    var id: Int { seq }
}

enum Changelog {

    /// Newest first, ordered by `seq`. Each entry is a tagged release whose
    /// `version` matches the git tag (see RELEASING.md). Curated from git
    /// history to user-facing changes.
    static let releases: [ReleaseNote] = [
        ReleaseNote(
            seq: 12, version: "0.11.0",
            date: "Jun 28, 2026",
            title: "Smarter AI opponents & partners",
            summary: "AI players bid and play much sharper now: a partner won't talk you out of an auction with a weak hand and then fold, and they cash their winners, hold the lead, and stop gifting tricks with careless leads."),
        ReleaseNote(
            seq: 11, version: "0.10.0",
            date: "Jun 28, 2026",
            title: "Save & resume your game",
            summary: "Solo games now save automatically after every move. Quit whenever you like and tap Continue on the home screen to pick up exactly where you left off."),
        ReleaseNote(
            seq: 10, version: "0.9.1",
            date: "Jun 28, 2026",
            title: "What's New & release tracking",
            summary: "Added this What's New page — reopen it anytime from Settings — plus a proper versioning system behind the scenes."),
        ReleaseNote(
            seq: 9, version: "0.9.0",
            date: "Jun 27, 2026",
            title: "Adjustable difficulty & Adaptive AI",
            summary: "A new difficulty slider dials the bots across the full skill ladder, plus an optional Adaptive mode for a tougher, search-driven opponent."),
        ReleaseNote(
            seq: 8, version: "0.8.0",
            date: "Jun 27, 2026",
            title: "Landscape support",
            summary: "Added landscape support, made the cards easier to read, and cleaned up under the hood."),
        ReleaseNote(
            seq: 7, version: "0.7.0",
            date: "Jun 17, 2026",
            title: "Smoother between matches",
            summary: "Improved the experience between matches and fixed the multiplayer between-match screen."),
        ReleaseNote(
            seq: 6, version: "0.6.0",
            date: "Jun 12, 2026",
            title: "Remote multiplayer & animations",
            summary: "Added the first version of remote multiplayer, along with new table animations and sound."),
        ReleaseNote(
            seq: 5, version: "0.5.0",
            date: "Jun 4, 2026",
            title: "Smarter opponents",
            summary: "Serious AI strategy improvements and better table visibility."),
        ReleaseNote(
            seq: 4, version: "0.4.0",
            date: "Jun 4, 2026",
            title: "Major AI rework",
            summary: "A ground-up rework of how the bots think, for stronger, more natural play."),
        ReleaseNote(
            seq: 3, version: "0.3.0",
            date: "Jun 3, 2026",
            title: "Tabletop mode",
            summary: "Use one device as the shared board while everyone else joins from their own."),
        ReleaseNote(
            seq: 2, version: "0.2.0",
            date: "May 20, 2026",
            title: "Local multiplayer",
            summary: "The interface became fully playable, and nearby devices could join a local table."),
        ReleaseNote(
            seq: 1, version: "0.1.0",
            date: "May 18, 2026",
            title: "First playable",
            summary: "The first playable version — intelligent AI opponents and live bidding."),
    ]

    /// The highest `seq` across all entries (the current release).
    static var latestSeq: Int { releases.map(\.seq).max() ?? 0 }

    /// The installed build number, read from the bundle — for display in the
    /// header. On Xcode Cloud builds this is the real number (e.g. 36).
    static var currentBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(Int.init)
    }

    /// The installed marketing version (e.g. "1.0"), for display.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Entries the player hasn't seen yet — `seq` greater than `lastSeenSeq`.
    static func releases(newerThan lastSeenSeq: Int) -> [ReleaseNote] {
        releases.filter { $0.seq > lastSeenSeq }
    }
}

// MARK: - "Show on update" gate

/// Decides whether the What's New pop-up should appear on launch, and records
/// the build the player has seen. Backed by `UserDefaults`.
@MainActor
enum WhatsNewGate {
    private static let lastSeenKey = "whatsNew.lastSeenSeq"

    /// The notes to present on launch, or `nil` if nothing should be shown.
    /// Records the latest `seq` silently on a fresh install (no pop-up for
    /// brand-new players). Call once per launch.
    static func notesToPresentOnLaunch() -> [ReleaseNote]? {
        let defaults = UserDefaults.standard

        guard let lastSeen = defaults.object(forKey: lastSeenKey) as? Int else {
            // First launch on this device — not an update. Record and stay quiet.
            defaults.set(Changelog.latestSeq, forKey: lastSeenKey)
            return nil
        }

        let new = Changelog.releases(newerThan: lastSeen)
        return new.isEmpty ? nil : new
    }

    /// Advance the remembered position to the latest entry. Called when the
    /// pop-up is dismissed.
    static func markCurrentBuildSeen() {
        UserDefaults.standard.set(Changelog.latestSeq, forKey: lastSeenKey)
    }
}

/// Identifiable wrapper so the launch pop-up can drive a `.sheet(item:)`.
struct WhatsNewPresentation: Identifiable {
    let id = UUID()
    let releases: [ReleaseNote]
}

// MARK: - Pop-up view

/// The What's New surface. Presented as a sheet from two places: automatically
/// on the first launch after an update (only the new entries), and manually
/// from Settings (the full history).
struct WhatsNewView: View {
    let releases: [ReleaseNote]
    var title: String = "What's New"
    let onClose: () -> Void

    private var latestSeq: Int? { releases.map(\.seq).max() }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    ForEach(releases) { release in
                        ReleaseCard(release: release,
                                    isLatest: release.seq == latestSeq)
                    }
                }
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }

            continueBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background bleeds under the safe areas; the foreground content above
        // stays within them.
        .background(TableFeltBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(TableStyle.tableGold)
                .shadow(color: TableStyle.tableGold.opacity(0.4), radius: 12)

            Text(title)
                .font(TableTypography.display(.largeTitle, weight: .heavy))
                .foregroundStyle(.white)

            Text(versionLine)
                .font(TableTypography.display(.subheadline))
                .foregroundStyle(.white.opacity(0.66))
                .monospacedDigit()
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, 6)
    }

    private var versionLine: String {
        if let build = Changelog.currentBuild {
            return "Version \(Changelog.currentVersion) · Build \(build)"
        }
        return "Version \(Changelog.currentVersion)"
    }

    private var continueBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(TableStyle.panelStroke)
            Button {
                SoundEffectPlayer.shared.play(.buttonSelect)
                onClose()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TablePillButtonStyle(tint: TableStyle.actionBlue))
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }
}

/// A single changelog entry rendered as a felt panel.
private struct ReleaseCard: View {
    let release: ReleaseNote
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("v\(release.version)")
                    .font(TableTypography.display(.caption, weight: .bold))
                    .monospacedDigit()
                    .tracking(0.4)
                    .foregroundStyle(TableStyle.feltBottom)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(TableStyle.tableGold))

                if isLatest {
                    Text("LATEST")
                        .font(TableTypography.display(.caption2, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(TableStyle.teamBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().stroke(TableStyle.teamBlue.opacity(0.6), lineWidth: 1))
                }

                Spacer()

                Text(release.date)
                    .font(TableTypography.display(.caption))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text(release.title)
                .font(TableTypography.display(.headline, weight: .bold))
                .foregroundStyle(.white)

            Text(release.summary)
                .font(TableTypography.display(.subheadline))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .tablePanel(cornerRadius: 14, shadowOpacity: 0.22)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isLatest ? TableStyle.tableGold.opacity(0.5)
                                 : TableStyle.panelStroke,
                        lineWidth: 1)
        }
    }
}

#Preview {
    WhatsNewView(releases: Changelog.releases, onClose: {})
}
