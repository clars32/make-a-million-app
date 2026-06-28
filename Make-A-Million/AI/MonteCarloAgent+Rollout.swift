//
//  MonteCarloAgent+Rollout.swift
//  Make-a-Million
//
//  Rollout policy hand-off, world evaluation, and the MCTS utility.
//  Split out of MonteCarloAgent.swift; same type via `extension MonteCarloAgent`.
//

import Foundation

extension MonteCarloAgent {

    // MARK: - Rollout + scoring

    /// `PlayoutPolicy.move` with THIS profile's rollout flags applied. The one
    /// place the lever set is spread, so the greedy rollout, the IS-MCTS tail,
    /// and the EndgameSolver's move ordering all drive the identical policy.
    func policyMove(in state: GameState, seat: PlayerID) -> Move {
        PlayoutPolicy.move(in: state, seat: seat,
                           commandingPull: difficulty.research.rolloutCommandingPull,
                           specialEscape: difficulty.research.rolloutSpecialEscape,
                           topPull: difficulty.rolloutTopPull,
                           establishDuck: difficulty.research.rolloutEstablishDuck,
                           bankWin: difficulty.research.rolloutBankWin)
    }

    /// Score one (world × candidate) continuation: roll the determinized
    /// state forward with the greedy PlayoutPolicy and return the utility of
    /// the settled hand. With `exactGate > 0`, hand off to EndgameSolver as
    /// soon as the side to act holds ≤ gate cards — the remainder of the
    /// hand is then played PERFECTLY by all four seats (each maximising its
    /// own team's utility) instead of greedily. When the root decision is
    /// inside the exact window the handoff fires on the first iteration, so
    /// no greedy step runs at all. If a solve exceeds its node budget
    /// (pathological width — does not happen at the intended gates), the
    /// gate is dropped for the rest of this continuation and the greedy
    /// policy finishes the hand: never a wrong answer, just a softer one.
    func evaluateWorld(_ start: GameState,
                               myTeam: Int,
                               baseline: [Int: Int],
                               exactGate: Int) -> Double {
        var s = start
        var steps = 0
        var solverLive = exactGate > 0
        while s.phase != .handComplete && steps < 600 {
            if solverLive, (s.hands[s.toAct]?.count ?? .max) <= exactGate {
                if let v = EndgameSolver.solve(s, myTeam: myTeam,
                                               policyGuess: { policyMove(in: $0, seat: $0.toAct) },
                                               leaf: {
                    utility($0, myTeam: myTeam, baseline: baseline)
                }) {
                    return v
                }
                solverLive = false
            }
            let mv = policyMove(in: s, seat: s.toAct)
            guard let ns = try? s.applying(mv, by: s.toAct) else { break }
            s = ns
            steps += 1
        }
        return utility(s, myTeam: myTeam, baseline: baseline)
    }

    func teamNet(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Int {
        let mine = (final.matchScore[myTeam] ?? 0) - (baseline[myTeam] ?? 0)
        let opp  = (final.matchScore[1 - myTeam] ?? 0) - (baseline[1 - myTeam] ?? 0)
        return mine - opp
    }

    /// The value MCTS maximises for one rolled-out world. Pure team net
    /// (dollars) by default; with `matchWinWeight > 0` it blends in match-win
    /// probability so play becomes match-aware: utility = net + W·P(win).
    /// teamNet already prices the made/set discontinuity (set-back flows
    /// through scoring); the P term adds the MATCH context it lacks — risking
    /// a set matters more at $900k than at $200k, and a hand that crosses the
    /// $1M line is worth everything. Logistic P keeps a useful gradient when
    /// the match is live and goes flat when it's lopsided, where the dollar
    /// term takes back over (the blend, not pure win-prob, for exactly that
    /// washout reason).
    func utility(_ final: GameState,
                         myTeam: Int,
                         baseline: [Int: Int]) -> Double {
        let net = Double(teamNet(final, myTeam: myTeam, baseline: baseline))
        let w = difficulty.matchWinWeight
        guard w > 0 else { return net }

        let mine = Double(final.matchScore[myTeam] ?? 0)
        let theirs = Double(final.matchScore[1 - myTeam] ?? 0)
        let goal = 1_000_000.0
        let p: Double
        if mine >= goal || theirs >= goal {
            if mine >= goal && theirs >= goal {
                // Both crossed on this hand: the standard endgame rule gives
                // the match to the team that won the bid.
                let bidTeam = final.highBidder.map { Seats.team(of: $0) }
                p = (bidTeam == myTeam) ? 1.0 : 0.0
            } else {
                p = mine >= goal ? 1.0 : 0.0
            }
        } else {
            // Logistic in the score lead; $300k of lead ≈ 73% to win. Scale
            // chosen so typical hand swings (±$200-400k) move P meaningfully
            // without saturating mid-match. TUNE alongside matchWinWeight.
            p = 1.0 / (1.0 + exp(-(mine - theirs) / 300_000.0))
        }
        return net + w * p
    }

}
