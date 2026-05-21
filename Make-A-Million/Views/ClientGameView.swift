//
//  ClientGameView.swift
//  Make-a-Million
//

import SwiftUI

struct ClientGameView: View {

    let playerName: String
    let hostName: String // Track who the host is
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

    // AUTOMATIC DETECTION: If the host isn't playing at seat 0, it's a tabletop game!
    private var isControllerMode: Bool {
        guard let firstSeatName = session.seatNames.first else { return false }
        return firstSeatName != hostName
    }

    var body: some View {
        ZStack {
            GameBody(
                tableView: tableView,
                decisionView: decisionView ?? tableView,
                isInteractive: isInteractive,
                caughtUp: session.caughtUp,
                endOfHandSnapshot: nil,
                pendingTick: pendingTick,
                displayTick: displayTick,
                seatNames: session.seatNames.isEmpty ? ["South", "West", "North", "East"] : session.seatNames,
                isControllerMode: isControllerMode, // Pass auto-detected state
                submit: { move in session.submit(move) },
                startAction: nil,
                dealAnother: nil,
                dealSeed: 0,
                onCaptureLastView: { lastView = $0 })
            .padding(.top, isControllerMode ? 20 : 0) // Visual comfort padding for landscape layout

            // Sleek utility overlay top bar
            VStack {
                HStack {
                    if isControllerMode {
                        Text("🎮 Controller Mode")
                            .font(.caption).bold()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    
                    Spacer()
                    
                    Button("Leave") {
                        session.stop()
                        onExit()
                    }
                    .buttonStyle(.bordered)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
                Spacer()
            }

            if case .paused(let reason) = session.phase {
                pausedOverlay(reason: reason)
            } else if session.phase == .disconnected {
                disconnectedOverlay
            }
        }
        // Force Landscape Orientation when playing on a Tabletop
        .onAppear {
            if isControllerMode {
                setOrientation(.landscapeRight)
            }
        }
        .onDisappear {
            if isControllerMode {
                setOrientation(.portrait)
            }
        }
    }

    // Native geometry request handler for orientation management
    private func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
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
