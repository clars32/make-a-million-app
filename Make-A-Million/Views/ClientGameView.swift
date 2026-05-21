//
//  ClientGameView.swift
//  Make-a-Million
//

import SwiftUI

struct ClientGameView: View {

    @ObservedObject var session: ClientSession
    let onExit: () -> Void

    @State private var lastView: PlayerView? = nil

    private var tableView: PlayerView? {
        session.displayView ?? session.pending ?? lastView
    }
    private var decisionView: PlayerView? {
        session.pending ?? session.displayView ?? lastView
    }
    private var isInteractive: Bool { session.pending != nil }

    private var pendingTick: Int {
        guard let p = session.pending else { return -1 }
        return GameBody.animationToken(p)
    }
    private var displayTick: Int {
        guard let d = session.displayView else { return -1 }
        return GameBody.animationToken(d)
    }

    private var endOfHandSnapshot: HandCompleteSnapshot? {
        guard case .handOver(let winner) = session.phase,
              let live = lastView ?? session.displayView else { return nil }
        return HandCompleteSnapshot(
            matchScore: live.matchScore,
            matchWinner: winner,
            bidHistory: live.bidHistory,
            opener: live.opener,
            debugReveal: nil)
    }

    var body: some View {
        ZStack {
            GameBody(
                tableView: tableView,
                decisionView: decisionView ?? tableView,
                isInteractive: isInteractive,
                caughtUp: session.caughtUp,
                endOfHandSnapshot: endOfHandSnapshot,
                pendingTick: pendingTick,
                displayTick: displayTick,
                seatNames: session.seatNames.isEmpty ? ["South", "West", "North", "East"] : session.seatNames, // NEW: Networked Names
                submit: { move in session.submit(move) },
                startAction: nil,
                dealAnother: nil,
                dealSeed: 0,
                onCaptureLastView: { lastView = $0 })

            VStack {
                HStack {
                    Spacer()
                    Button("Leave") {
                        session.stop()
                        onExit()
                    }
                    .buttonStyle(.bordered)
                    .padding()
                }
                Spacer()
            }

            if case .paused(let reason) = session.phase {
                pausedOverlay(reason: reason)
            } else if session.phase == .disconnected {
                disconnectedOverlay
            }
        }
    }

    // MARK: Overlays

    private func pausedOverlay(reason: PauseReason) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Table paused")
                    .font(.title3).bold().foregroundStyle(.primary)
                Text(messageFor(reason))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Waiting for the host…")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.horizontal, 28)
        }
    }

    private var disconnectedOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("Disconnected").font(.title3).bold().foregroundStyle(.primary)
                Text("Lost connection to the host.")
                    .foregroundStyle(.secondary)
                Button("Back to menu") {
                    session.stop()
                    onExit()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.horizontal, 28)
        }
    }

    private func messageFor(_ reason: PauseReason) -> String {
        switch reason {
        case .playerDisconnected(_, let name):
            return "\(name) lost connection."
        }
    }
}
