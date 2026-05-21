//
//  TabletopGameView.swift
//  Make-a-Million
//

import SwiftUI

struct TabletopGameView: View {

    @ObservedObject var netSession: NetSession
    @ObservedObject var gameSession: GameSession
    let onExit: () -> Void

    @State private var lastView: PlayerView? = nil

    private var tableView: PlayerView? {
        gameSession.displayView ?? lastView
    }

    private var displayTick: Int {
        guard let d = gameSession.displayView else { return -1 }
        return GameBody.animationToken(d)
    }

    private var endOfHandSnapshot: HandCompleteSnapshot? {
        guard let s = gameSession.finished else { return nil }
        // For the tabletop, we can safely reveal the debug hands at the end if desired
        return HandCompleteSnapshot(
            matchScore: s.matchScore,
            matchWinner: s.matchWinner,
            bidHistory: s.bidHistory,
            opener: Seats.next(s.dealer),
            debugReveal: s.debugReveal())
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.green.opacity(0.15), Color.teal.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Top Bar
                HStack {
                    Text("Tabletop Mode")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("End Match") {
                        netSession.stop()
                        onExit()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal)
                .padding(.top)

                if let snapshot = endOfHandSnapshot {
                    handCompleteView(snapshot)
                } else if let table = tableView {
                    activeBoardView(table: table)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().scaleEffect(1.5)
                        Text("Waiting for hand to start...")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .onChange(of: displayTick) { _, _ in
                if let d = tableView { lastView = d }
            }

            if case .paused(let reason) = netSession.phase {
                pausedOverlay(reason: reason)
            }
        }
    }

    // MARK: - Active Board Layout

    private func activeBoardView(table: PlayerView) -> some View {
        VStack(spacing: 24) {
            
            // 1. Scores & Status at the top
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    statusLine(table)
                    if table.phase == .bidding || !table.bidHistory.isEmpty {
                        bidHistoryPanel(records: table.bidHistory, opener: table.opener)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                scoreBar(table)
                    .frame(maxWidth: 350)
            }
            .padding(.horizontal)

            Spacer()

            // 2. The Centerpiece: The Trick in Progress
            if let trick = table.currentTrick, !trick.plays.isEmpty {
                VStack(spacing: 16) {
                    Text("Current Trick")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 20) {
                        ForEach(trick.plays, id: \.player.raw) { play in
                            VStack(spacing: 8) {
                                Text(seatName(play.player))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                largeCardChip(play.card)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                }
            } else if let widow = table.widow, !widow.isEmpty {
                widowPanel(widow, highBidder: table.highBidder)
            } else {
                Text("Waiting for next play...")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // 3. Last Trick at the bottom
            if let last = table.lastTrick {
                lastTrickPanel(last)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: - Reused & Scaled UI Components
    // These are adapted from GameBody but scaled up for an iPad display.

    private func largeCardChip(_ card: Card) -> some View {
        let safeTint = card.tint == .primary ? Color.black : card.tint
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.shortLabel)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                Circle()
                    .fill(safeTint)
                    .frame(width: 12, height: 12)
            }
            .padding(.top, 12)
            .padding(.leading, 12)
            .foregroundStyle(safeTint)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
        .frame(width: 110)
        .aspectRatio(2.5 / 3.5, contentMode: .fit)
    }

    private func scoreBar(_ view: PlayerView) -> some View {
        let live = view.liveHandScore
        let names = netSession.seats.map(\.name)
        let teamA = names.count == 4 ? "\(names[0]) + \(names[2])" : "Team A"
        let teamB = names.count == 4 ? "\(names[1]) + \(names[3])" : "Team B"

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(teamA).font(.headline).foregroundStyle(.blue)
                Text("Hand $\(live[0, default: 0] / 1000)k").font(.system(.title2, design: .rounded).bold().monospacedDigit())
                Text("Match $\(view.matchScore[0, default: 0] / 1000)k").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Text("vs").font(.headline).foregroundStyle(.tertiary)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(teamB).font(.headline).foregroundStyle(.secondary)
                Text("Hand $\(live[1, default: 0] / 1000)k").font(.system(.title2, design: .rounded).bold().monospacedDigit())
                Text("Match $\(view.matchScore[1, default: 0] / 1000)k").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusLine(_ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(view.phase.headline).font(.system(.title, design: .rounded)).bold()
            if let t = view.trump {
                HStack(spacing: 8) {
                    Circle().fill(t.swatch).frame(width: 16, height: 16)
                    Text("Trump: \(t.displayName)")
                        .font(.title3.bold())
                        .foregroundStyle(t.swatch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(t.swatch.opacity(0.15)))
            }
        }
    }

    private func lastTrickPanel(_ last: CompletedTrickInfo) -> some View {
        HStack(spacing: 12) {
            Text("Last trick").font(.headline).foregroundStyle(.secondary)
            ForEach(last.plays, id: \.player.raw) { play in
                HStack(spacing: 4) {
                    Text(seatShort(play.player)).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(play.card.shortLabel).font(.subheadline.bold()).foregroundStyle(play.card.tint)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
            }
            Spacer()
            Text("\(seatName(last.winner)) won $\(last.value / 1000)k")
                .font(.system(.headline, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(last.winner.raw % 2 == 0 ? Color.green : Color.orange)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func widowPanel(_ widow: [Card], highBidder: PlayerID?) -> some View {
        VStack(spacing: 16) {
            Text("The Widow")
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(widow, id: \.shortLabel) { card in
                    largeCardChip(card)
                }
            }
            if let bidder = highBidder {
                Text("\(seatName(bidder)) won the bid")
                    .font(.headline)
                    .foregroundStyle(bidder.raw % 2 == 0 ? Color.green : Color.orange)
            }
        }
    }

    private func handCompleteView(_ s: HandCompleteSnapshot) -> some View {
        VStack(spacing: 16) {
            Text(s.matchWinner != nil ? "Match Complete!" : "Hand Complete")
                .font(.largeTitle).bold()
            if let winner = s.matchWinner {
                Text(winner == 0 ? "Team A Wins!" : "Team B Wins!")
                    .font(.title2).foregroundStyle(.green)
            }
            // You can embed HandRevealPanel here if you want to show everyone's dealt hands
            // at the end of the round on the iPad.
        }
    }

    // Abridged bid history panel for the tabletop
    private func bidHistoryPanel(records: [BidRecord], opener: PlayerID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bidding").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(records.suffix(6), id: \.player.raw) { record in // Show last 6 bids
                    Text("\(seatShort(record.player)): \(record.action == .pass ? "Pass" : "$\( (record.action == .pass ? 0 : 15) )k")") // simplified bid label
                        .font(.subheadline)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pausedOverlay(reason: PauseReason) -> some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Table Paused").font(.largeTitle).bold()
                Text("A player lost connection. Waiting for them to return.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func seatName(_ p: PlayerID) -> String {
        let names = netSession.seats.map(\.name)
        guard p.raw < names.count else { return "Seat \(p.raw)" }
        return names[p.raw]
    }
    
    private func seatShort(_ p: PlayerID) -> String {
        String(seatName(p).prefix(3)).uppercased()
    }
}
