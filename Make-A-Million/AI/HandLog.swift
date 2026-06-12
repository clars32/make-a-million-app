//
//  HandLog.swift
//  Make-a-Million
//
//  A full-INFORMATION, human-and-Claude-readable trace of one completed hand.
//  The point: once AI mistakes get subtle, you can't spot them from your own
//  seat (you can't see the other hands). This dumps everything — all four
//  dealt hands, the widow, the whole bid sequence, the reconstructed declarer
//  discard, every trick in play order with raw vs Bull/Bear-adjusted value,
//  and a running score — so a reviewer can judge each AI decision against the
//  strategy principles with perfect information.
//
//  It is a PURE function of the final GameState (which already carries
//  `dealtHands`, `dealtWidow`, `bidHistory`, and every `completedTrick`), so
//  it adds no engine plumbing and leaks nothing mid-hand: it only renders once
//  a hand is over. The declarer's three discards aren't stored anywhere, but
//  they're recoverable — they are exactly (dealt hand ∪ widow) minus the 13
//  cards the declarer actually played.
//
//  ENGINE BINDING: GameState.{dealtHands, dealtWidow, bidHistory, trump,
//  highBidder, highBid, dealer, completedTricks, matchScore,
//  discardAnnouncement, debugReveal()} ;
//  GameState.trickWinner / trickValue ; Trick.ledColor ; Card.moneyValue ;
//  Seats.{all, team}.
//

import Foundation

nonisolated enum HandLog {

    private static let shortSeats = ["S", "W", "N", "E"]

    /// Render one completed hand. `seatLabels` are the full names shown in the
    /// deal block (e.g. "South (You · human)", "West (AI)"); pass them in seat
    /// order 0…3. Safe to call only at `.handComplete`.
    static func render(_ final: GameState,
                       handIndex: Int,
                       seatLabels: [String],
                       decisions: (plays: [AIDecisionTrace.PlayDecision],
                                   bids: [AIDecisionTrace.BidDecision])
                                = (plays: [], bids: [])) -> String {
        let trump = final.trump ?? .red
        let declarer = final.highBidder
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }

        // ---- Header
        line("════════════════ HAND \(handIndex + 1) ════════════════")
        line("dealer: \(name(final.dealer, seatLabels))"
             + "   trump: \(final.trump.map(colorName) ?? "—")"
             + "   contract: \(money(final.highBid))")
        if let d = declarer { line("declarer: \(name(d, seatLabels))") }
        line()

        // ---- Deal (full information)
        line("DEAL (full information)")
        let width = seatLabels.map(\.count).max() ?? 16
        for s in Seats.all {
            let hand = (final.dealtHands[s] ?? []).sorted { sortKey($0) > sortKey($1) }
            let label = name(s, seatLabels).padding(toLength: width, withPad: " ", startingAt: 0)
            line("  \(label)  T\(Seats.team(of: s))  "
                 + hand.map(token).joined(separator: " "))
        }
        line("  Widow: " + final.dealtWidow.map(token).joined(separator: " "))
        line()

        // ---- Bidding
        line("BIDDING")
        let bids = final.bidHistory.map { "\(short($0.player)) \(bidText($0.action))" }
        line("  " + (bids.isEmpty ? "(none)" : bids.joined(separator: " · ")))
        if let d = declarer {
            let discard = reconstructDiscard(final, declarer: d)
            if !discard.isEmpty {
                line("  discard (\(short(d))): "
                     + discard.map(token).joined(separator: " ")
                     + "   [reconstructed]")
            }
            if let ann = final.discardAnnouncement {
                line("  announced: \(ann.trumpCount) trump"
                     + (ann.moneyCards.isEmpty ? "" : " · money shown: "
                        + ann.moneyCards.map(token).joined(separator: " ")))
            }
        }
        if !decisions.bids.isEmpty {
            line("  AI bid reasoning:")
            for b in decisions.bids {
                line("    \(short(b.seat)) → \(b.chosen)"
                     + "   (valuation \(money(b.valuationGross)),"
                     + " ceiling \(money(b.ceiling)))")
                for n in b.notes { line("        · \(n)") }
            }
        }
        line()

        // ---- Tricks
        line("TRICKS  (* = winner; eff = value after Bull/Bear)")
        var running: [Int: Int] = [0: 0, 1: 0]
        var flags: [String] = []
        for (i, t) in final.completedTricks.enumerated() {
            let winner = GameState.trickWinner(t, trump: trump)
            let raw = t.plays.reduce(0) { $0 + $1.card.moneyValue }
            let eff = GameState.trickValue(t)
            running[Seats.team(of: winner), default: 0] += eff
            let ledChar = t.ledColor(trump: trump).map(colorInitial) ?? "?"
            let plays = t.plays.map { pc -> String in
                "\(short(pc.player)):\(token(pc.card))\(pc.player == winner ? "*" : "")"
            }.joined(separator: "  ")
            line("  \(pad(i + 1))[\(ledChar)] \(plays)")
            line("       → \(short(winner)) wins   raw \(money(raw)) eff \(money(eff))"
                 + "   (T0 \(money(running[0])) / T1 \(money(running[1])))")

            // AI reasoning for each play in this trick (when captured): the
            // scored shortlist + the table-read that picked the branch.
            for pc in t.plays {
                guard let d = decisions.plays.first(where: {
                    $0.seat == pc.player && $0.chosen == pc.card
                }) else { continue }
                for l in playDecisionLines(d) { line(l) }
            }

            // High-confidence flag: money landed in a trick worth $0 (Beared).
            if eff == 0 && raw > 0 {
                let moneyCards = t.plays.filter { $0.card.moneyValue > 0 }
                    .map { "\(short($0.player)):\(token($0.card))" }.joined(separator: " ")
                flags.append("Trick \(i + 1): \(money(raw)) of money landed in a $0 (Beared) trick — \(moneyCards)")
            }
        }
        line()

        // ---- Result
        if let rv = final.debugReveal() {
            line("RESULT")
            line("  bid team gross \(money(rv.bidTeamGross)) vs contract \(money(rv.contract)) → "
                 + (rv.made ? "MADE" : "SET"))
            line("  opponents gross \(money(rv.otherGross))")
            line("  match score: T0 \(money(final.matchScore[0])) · T1 \(money(final.matchScore[1]))")
            line()
        }

        // ---- Heuristic flags (look-here hints, not certain mistakes)
        line("HEURISTIC FLAGS (look-here hints, not certain mistakes)")
        if flags.isEmpty {
            line("  none")
        } else {
            for f in flags { line("  ⚠ " + f) }
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// The declarer's three discards = (dealt hand ∪ widow) − the 13 cards they
    /// played over the hand. Empty unless the hand actually completed.
    private static func reconstructDiscard(_ final: GameState,
                                           declarer: PlayerID) -> [Card] {
        let available = Set((final.dealtHands[declarer] ?? []) + final.dealtWidow)
        let played = Set(final.completedTricks
            .flatMap { $0.plays }
            .filter { $0.player == declarer }
            .map(\.card))
        return available.subtracting(played).sorted { sortKey($0) > sortKey($1) }
    }

    // MARK: - Formatting helpers

    private static func name(_ p: PlayerID, _ labels: [String]) -> String {
        labels.indices.contains(p.raw) ? labels[p.raw] : "Seat \(p.raw)"
    }
    /// Seat initial (S/W/N/E). Internal so the AI decision trace formats seats
    /// the same way the trick lines do.
    static func short(_ p: PlayerID) -> String {
        shortSeats.indices.contains(p.raw) ? shortSeats[p.raw] : "\(p.raw)"
    }
    /// Compact, UNAMBIGUOUS card token: color initial + rank (e.g. "B$40",
    /// "R11", "Y8", "G$30"), specials as "TGR"/"BUL"/"BER". The bare
    /// `shortLabel` omits the suit, which a full-information trace must show.
    /// Internal so the AI decision trace labels cards identically.
    static func token(_ c: Card) -> String {
        switch c {
        case .colored(let col, let r):
            return colorInitial(col) + rankLabel(r)
        case .tiger: return "TGR"
        case .bull:  return "BUL"
        case .bear:  return "BER"
        }
    }

    static func colorName(_ color: CardColor) -> String {
        switch color {
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .black: return "Black"
        case .green: return "Green"
        }
    }

    static func colorInitial(_ color: CardColor) -> String {
        switch color {
        case .red: return "R"
        case .yellow: return "Y"
        case .black: return "B"
        case .green: return "G"
        }
    }

    private static func rankLabel(_ rank: Card.Rank) -> String {
        switch rank {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .money5k: return "$5"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .money10k: return "$10"
        case .eleven: return "11"
        case .money15k: return "$15"
        case .money30k: return "$30"
        case .money40k: return "$40"
        }
    }
    /// Render one captured trick-play decision as indented trace lines:
    /// the chosen card, the scored shortlist (mean team net per candidate,
    /// `*` on the pick), and the table-read notes.
    private static func playDecisionLines(_ d: AIDecisionTrace.PlayDecision) -> [String] {
        var out: [String] = []
        let mark = d.blundered ? "   ⚠ blunder (deliberate non-best)" : ""
        out.append("       ↳ \(short(d.seat)) chose \(token(d.chosen))\(mark)")
        if !d.candidates.isEmpty {
            let cand = d.candidates.map { c -> String in
                "\(token(c.card)) \(signedMoney(c.meanNet))"
                    + (c.card == d.chosen ? "*" : "")
            }.joined(separator: " · ")
            out.append("           shortlist (mean team net/world): \(cand)")
        }
        for n in d.notes { out.append("           \(n)") }
        return out
    }

    /// Signed money for a NET score, which can be negative (e.g. "+$12.3k",
    /// "−$4.0k"). Kept to one decimal so close calls between candidates show.
    private static func signedMoney(_ v: Double) -> String {
        let k = v / 1000.0
        let sign = k < 0 ? "−" : "+"
        return String(format: "%@$%.1fk", sign, abs(k))
    }
    private static func bidText(_ a: BidAction) -> String {
        switch a {
        case .pass: return "pass"
        case .bid(let n): return "$\(n / 1000)k"
        }
    }
    private static func money(_ v: Int?) -> String {
        guard let v = v else { return "—" }
        return "$\(v / 1000)k"
    }
    private static func pad(_ n: Int) -> String {
        let s = "\(n)"
        return s.count >= 2 ? s + " " : " " + s + " "
    }

    /// High → low ordering for a readable hand: group by color, then rank,
    /// specials at the end.
    private static func sortKey(_ c: Card) -> Int {
        switch c {
        case .colored(let col, let r): return 100 + col.rawValue * 13 + r.rawValue
        case .tiger: return 92
        case .bull:  return 91
        case .bear:  return 90
        }
    }
}

// MARK: - File sink (debug capture)

extension HandLog {

    /// Where the running log is written when file logging is enabled. Lives in
    /// the app's Documents directory so it can be exported via a share sheet.
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
        return dir.appendingPathComponent("MakeAMillion-handlog.txt")
    }

    /// Append a rendered hand to the running log file (creating it if needed).
    static func append(_ text: String) {
        let data = Data((text + "\n\n").utf8)
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Delete the running log file.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// True if a log file currently exists (so the UI can show/hide Export).
    static var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}
