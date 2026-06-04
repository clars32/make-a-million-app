//
//  HostGameView.swift
//  Make-a-Million
//

import SwiftUI

struct HostGameView: View {

    @ObservedObject var netSession: NetSession
    @ObservedObject var gameSession: GameSession
    @ObservedObject var human: HumanAgent

    let onExit: () -> Void

    @State private var lastView: PlayerView? = nil
    @State private var showingSettings = false

    private var tableView: PlayerView? {
        gameSession.displayView ?? human.pending ?? lastView
    }
    private var decisionView: PlayerView? {
        human.pending ?? gameSession.displayView ?? lastView
    }
    private var isInteractive: Bool { human.pending != nil }

    private var pendingTick: Int {
        guard let p = human.pending else { return -1 }
        return GameBody.animationToken(p)
    }
    private var displayTick: Int {
        guard let d = gameSession.displayView else { return -1 }
        return GameBody.animationToken(d)
    }

    private var endOfHandSnapshot: HandCompleteSnapshot? {
        guard let s = gameSession.finished else { return nil }
        return HandCompleteSnapshot(
            matchScore: s.matchScore,
            matchWinner: s.matchWinner,
            bidHistory: s.bidHistory,
            opener: Seats.next(s.dealer),
            debugReveal: s.debugReveal())
    }

    var body: some View {
        ZStack {
            GameBody(
                tableView: tableView,
                decisionView: decisionView ?? tableView,
                isInteractive: isInteractive,
                caughtUp: gameSession.caughtUp,
                endOfHandSnapshot: endOfHandSnapshot,
                pendingTick: pendingTick,
                displayTick: displayTick,
                seatNames: netSession.seats.map(\.name), // NEW: Networked Names
                submit: { move in human.submit(move) },
                startAction: nil,
                dealAnother: {
                    if let s = gameSession.finished, s.matchWinner != nil {
                        netSession.start(dealSeed: .random(in: .min ... .max))
                    } else {
                        netSession.startNextHand()
                    }
                },
                dealSeed: 0,
                onCaptureLastView: { lastView = $0 })

            VStack {
                HStack(spacing: 8) {
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Settings")
                    Button("End") {
                        netSession.stop()
                        onExit()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            }

            if case .paused(let reason) = netSession.phase {
                pausedOverlay(reason: reason)
            }
        }
        .sheet(isPresented: $showingSettings) {
            // Rules lock while a hand is being played; display toggles stay live.
            SettingsView(settings: .shared,
                         rulesLocked: netSession.phase == .running) {
                showingSettings = false
            }
        }
    }

    private func pausedOverlay(reason: PauseReason) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Table paused").font(.title3).bold().foregroundStyle(.primary)
                Text(messageFor(reason))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    Button {
                        netSession.resumeWithBot()
                    } label: {
                        Text("Fill seat with bot and continue")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        netSession.stop()
                        onExit()
                    } label: {
                        Text("End match")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
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

    private func messageFor(_ reason: PauseReason) -> String {
        switch reason {
        case .playerDisconnected(_, let name):
            return "\(name) lost connection. Waiting for them to come back, or fill their seat with a bot to keep going."
        }
    }
}
