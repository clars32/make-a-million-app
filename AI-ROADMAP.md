# AI roadmap

House methodology (see `memory/ai-tuning-harness-and-findings.md`): **diagnose
with the harness before coding, keep Traditional changes legible + ladder-monotone,
confirm any self-play A/B at ≥100 matches, and remember that defense / strong-human
fixes can be invisible to symmetric self-play** — judge them by the targeted
diagnostic + handlog, not win-rate.

---

## July 2 2026 — full-stack review pass (shipped + measured)

A structured review of the whole AI stack ranked the remaining headroom; the
top items were implemented and measured in one pass. Quick suite 126/126 green
throughout. Per-lever record (every lever A/B-able; probes paired vs same-seed
champion, baseSeed 1 unless noted).

**⚠️ METHOD FINDING that reframes the win-rate reads below (measured last,
applies to all of them):** the IDENTICAL-PROFILE noise control for the
baseSeed-1 / N=100 / `.normal` family read **62% challenger, set-rate 22% vs
33%** — the family null is NOT 50%, and even the set-rate signature appears
under the null. Every same-family win-rate "edge" below (55-65%) is therefore
treated as **noise-compatible**; levers are kept on their NON-win-rate
grounds (instrument, diagnostic, correctness/robustness precedent, or a
within-family on-vs-off contrast, as noted per lever). Rule going forward:
never judge a single-family read against nominal 50% — pair every A/B with an
identical-profile control on the same family, and replicate across families.

**A1 — auction-aware scalar bidding (`bidPartnerRead`, skilled+expert).**
Diagnosis first (`runPartnerConditionedCalibration`, NEW instrument, 320 expert
forced-declarer hands): the auction-blind scalar mis-prices by the table's
public signals — partner would-pass band residual **−$30k** (make-at-est 25%),
partner-strong band **+$38k** (71%), quiet-table (both opps <225k) **+$37k**,
opponent-strong **+$2k ≈ 0** (the unconditional calibration is already
contested-table-dominated, so an opponent BID needs no correction). Shipped
offsets (see `scalarAuctionOffset`): partner passed −$25k (full size — the
anti-set direction), partner bid +$10k / opp passed +$12k each (damped:
observable bids only bound valuations from below, and the bucketings share
covariance). Self-play A/B at N=100 (expert on-vs-off): 57%/43%, bid share
53%, set 27%/32% — read as NEUTRAL-OR-BETTER given the family-null finding.
SHIPPED ON INSTRUMENT GROUNDS (the measured ±$30-38k residuals are the
justification, as the calibrated tables were): honest per-auction valuation,
neutral-or-better in self-play, and the real target — the strong-human
auction — is invisible to symmetric self-play anyway (the bidEntryMargin
lesson). Judge it in the next handlog.

**A2 — auction strength-window world weighting
(`research.auctionWindowWeighting`).** The named "world inference" lever: each
hidden non-declarer seat's bid-time hand is reconstructible (sampled remainder
+ public plays); its auction actions bound its strength as a WINDOW (bid $Y ⇒
ceiling ≳ Y; passed a raise to $X ⇒ ceiling ≲ X; partner-stander passes and
never-raised floor opens excluded as uninformative). Soft one-sided
importance weights (floor 0.25), never rejection — the rationality model is
the population's LITERAL bid policy, dodging the donation-filter mismatch
trap. **NOT PROMOTED — the family-null lesson in action.** The baseSeed-1
probe read 65% (N=60) and 62% (N=100)… and the identical-profile control
read the SAME 62% with the same set-rate gap. Worse, the lever-on run's
telemetry was near-identical to the control's, i.e. at strength 1.0 its
decisions rarely diverge from unweighted play — plausibly because
`bidLeanStrength` already pulls sampled worlds INSIDE the windows (the same
redundancy that parked `declarerTrumpBias`). Fresh-family re-read (baseSeed
777, N=100): **50%/50% exactly** (set 25%/27%) with the 777 identical-profile
control at a healthy 46% — the lever measures NOTHING on a clean family, and
the baseSeed-1 null really was a ~1% family tail draw (not a mechanical
harness bug — the 777 A/B would have inherited any mechanical challenger
bias and didn't). PARKED default-off, fully wired and A/B-able; the
salvageable variants are (a) windows with `bidLeanStrength` turned DOWN
(remove the redundancy) or (b) windows in the BID-rollout sampler, where the
lean is weaker.

**A3 — joint trump naming (`jointTrumpNaming`, all tiers, default on).** Each
color scored by its best 13-card KEEP (max over the shared discard shortlist,
engine-legal via `legalWidowDiscards`) instead of the raw 16-card valuation
(which inflates trump length and can't see discard-created voids). N=60
(Normal on-vs-off): 58%/42%, same bid share/contracts, set 26%/32% — read as
neutral-or-better under the family null. KEPT ON CORRECTNESS GROUNDS (the
`calibratedValuation` precedent: honest valuation ships on neutral).

**B1 — void-aware discard shortlist (`discardCandidates`).** The cost-ranked
shortlist prefix drops suit-EMPTYING combos (a singleton 7 loses the rank sort
to 2-3-4s but wins on void value); the cheapest legal combo emptying each side
suit is now always evaluated. Shared by discard + joint naming; covered by the
A3 probe above.

**B3 — expert exact endgame (`exactEndgameTricks: 2` on the expert preset,
root-only form in `resolveForkBySearch`).** "Counts the last tricks exactly" —
the promoted Hard/Extreme ROOT form, deliberately NOT the parked-negative
mid-hand tail form. N=100 (expert gate-2 vs 0): 55%/45%, set 23%/28% —
neutral-or-better under the family null, which is exactly the bar the
Adaptive root lever was promoted on (neutral strength + structural immunity
to the greedy-tail endgame class + the expert blurb's literal promise). KEPT.

**B5 — Bear-guard on tie-break banking (both stacks).** `bankToOwnTeam` no
longer banks max money into a trick a provably-void opponent can Bear
(`opponentCanBearTrick`, counting-level, so novice/casual unchanged). Scoped
to exactly the near-tie window the search can't defend. Bear diagnostic
(120 expert hands, same seeds as the June 29 baseline): avoidable follow-won
losses **$5k → $3.0k/hand**; forced last-trick loss unchanged (~$16k,
structural — the June lesson holds), total ~flat at $25k/hand. The correctly-
scoped version of the June `.bearGuard` attempt, without its relocation
pathology.

**B4 — closing bid (`bidToClose`, default on).** Near the finish line, when
the decision figure covers what the team still needs, a MAKE ends the match —
skip the leader's ceiling shrink (never inflate it). Ahead-start conditional
instrument (875k/625k, N=60), a WITHIN-family on-vs-off contrast so it
survives the family-null caveat: lever ON the leader wins **93%** (bid share
51%); the strict OFF-vs-off control wins only **80%** with bid share
collapsed to **13%** — the shrink was making the leader pass nearly
everything and defend, handing back one match in eight. **+13pp**, the
session's cleanest validated win. Self-gating like `matchWinWeight` (inert
until a hand can close).

**Nits shipped:** `outstandingMoney` gated to counting-level (consistency);
`forceRuffLead` requires trump still out; stale "joint optimisation" header
comment fixed.

**Follow-ups (next session):**
- (RESOLVED same session) The 62% identical-profile null was a ~1% family
  tail draw, not a mechanical bug: the 777-family control read a healthy 46%
  and the 777 A2 A/B read exactly 50% (a mechanical challenger bias would
  have shown in both). Standing rule: every win-rate A/B gets a same-family
  identical-profile control, and promotion needs a fresh-family replication.
- A2 revival candidates: windows with `bidLeanStrength` turned DOWN (remove
  the redundancy), or in the BID rollout sampler where the lean is weaker.
- Re-run `testTraditionalLadderMonotonicity` (arena, long) before the next
  release cut — A1/B3 strengthen skilled/expert only, so monotonicity should
  only widen, but confirm.
- The haircut coefficient (0.35) was tuned pre-A1; a re-sweep
  (`runBidHaircutSweep`) on the auction-adjusted estimates is cheap insurance.
- Handlog a real game vs a strong human (the loop that caught Items 1-2) —
  it is the real judge of A1 and B5, which target strong-human patterns that
  symmetric self-play can't see.

---

# Resolved earlier items (June 2026)

Surfaced by the v0.11.0 play-test handlog (`MakeAMillion-handlog 7.txt`, expert AI
vs a strong human). Both cost more than the lead leaks that v0.11.0 fixed.

---

## RESOLUTION (June 29 2026)

**Item 1 — SHIPPED.** `bidSetRiskHaircut` (scalar bidder, skilled+expert at 0.35).
Diagnosis (`testBidCalibrationTraditionalExpert`): the calibrated evaluator is
MEAN-unbiased (+$7k) but only makes its own valuation ~52% of the time, REGRESSIVE
(high estimates over-predict and walk into sets — ~41% make on ≥$225k hands, low
estimates under-predict). The haircut shaves a fraction of the valuation's EXCESS
over the opening floor: it bites the over-valued high tail hardest and, since the
cut is always < the excess, NEVER converts a biddable hand to a pass (so it can't
worsen the evaluator's known weak-hand conservatism). Coefficient chosen by
`runBidHaircutSweep` (the analytic, one-playout-pass instrument) — `est−floor` at
0.35 lifted high-band make 41→65% with only a $9k cut on the (under-valued) low
band, dominating the off-suit / Bear-able proxies on targeting. VALIDATED at 100
matches: set-rate **35→22%**, win-rate 63% (not just neutral — avoiding
full-contract setbacks wins games), avg contract unchanged. Ladder monotone
(casual>novice 57, skilled>casual 67, expert>skilled 58; higher rung sets less in
every pairing).

**Item 2 — PARKED (negative result).** Diagnosis (`testDiagnoseBearAgainstUs`):
$25k/hand Beared against the winner, $10k avoidable (split ~evenly money-LED vs
follow-won), $15k forced (last trick). The `.bearGuard` candidate fixes (follow:
win with junk under a live Bear; lead: skip money into a known void / bait the Bear
out of a cashed money trump) were implemented and A/B'd with opponents held FIXED
(only the test team toggled, bidding identical): NEUTRAL on the provable-void
trigger ($11.0→$11.1k against the test team), and WORSE when broadened to "Bear
loose + opponent behind" ($11.0→$13.4k, forced +$2.2k). Mechanism: deferring/
hoarding money to dodge the single Bear just RELOCATES the loss to the forced
endgame, where it's caught anyway; and the Bear-holder's void isn't PROVABLE at
decision time (the opponent reveals it by Bearing). A probabilistic threat model
over-fires. Candidate fix 3 (EndgameSolver gate) is an ADAPTIVE-stack feature, not
reachable from the Traditional ladder. Reverted the play-side code; kept the
diagnostic as the yardstick for any future attempt (would need single-observer
inference of the Bear's location, or moving expert onto a stack with exact endgame).

---

## Item 1 — Traditional bidder over-values, walks into sets

**Evidence.** Handlog 7, Hand 3: West (expert) valued its hand at **$344k**, bid
$265k, captured **$195k** → set by $70k. West (the AI pair) was set twice in the
game, driving the −$430k blowout.

**Root cause.** The Traditional stack bids on the **mean** gross:
`decideBidTraditional → decideBid` reads `HandEvaluator.bestValuation(...).expectedGross`
with `rolloutBidEval = false` (Traditional presets). There is **no set-risk
pricing**. The Adaptive stack already solved this with `rolloutBidEval` (the
P(make) quantile, validated p=0.45) but it's deliberately Adaptive-only
(Traditional = legible scalar, no rollouts). The evaluator tables were calibrated
(June 2026) against **MC self-play defense**, which is weaker than a strong human
(Bears, accurate play), so the mean under-prices defense.

> Note: the `bidEntryMargin` gate shipped in v0.11.0 is about not *misleading the
> partner*; it is orthogonal to this. This item is the absolute **bid level**.

**Diagnose first.**
- Re-run `AIArena.runBidCalibration` (`testBidCalibration`, the opponent-free
  instrument) on the expert/Traditional tables. Read the **bid-population
  make-rate** (target ~85%); the dollar gap is inflated and secondary. If bids
  make <~70%, it's over-bidding. Memory previously found *under*-valuation in
  self-play — confirm whether, against the calibrated tables + a stronger defense
  model, it now over-values.
- Tag a few human games via handlog and compare `expectedGross` to captured gross.

**Candidate fixes (ranked).**
1. **(Preferred, legible) Set-risk haircut on the scalar valuation.** Bid on a
   discounted figure where the discount is a cheap, explainable proxy for variance
   — e.g. grows with how much of the gross sits in *beatable / Bear-able* cards
   (money that depends on winning a contested or zeroable trick). Tune the
   coefficient so the calibration make-rate lands ~85%. Stays scalar + legible.
2. **(Alternative) Recalibrate `HandEvaluator.Tables` downward for defense** —
   lower priority: the calibration harness uses MC defense, so it can't *see*
   strong-human defense; risky to recalibrate against the wrong yardstick.
3. **(Last resort, breaks legibility) Lightweight distribution-aware Traditional
   bid** — a few rollouts → P(make) quantile, like `rolloutBidEval` but cheaper.
   Only if (1) is insufficient; it breaks the "Traditional = no rollouts" design.

**Validate.** Primary metric = calibration make-rate (~85%); self-play win-rate is
insensitive to bid aggression (documented). Ladder monotonicity must hold; per-tier
set-rate should fall. Confirm at ≥100.

---

## Item 2 — Bear endgame defense

**Evidence.** Handlog 7: the human zeroed a **$40–65k** trick with the Bear in
Hands 1, 2, and 3 (every hand; the per-hand HEURISTIC FLAG already prints these).
E.g. Hand 1 t13: West won a trick worth $65k (`Y$40`+`R$15`+`G$10`) and the human's
`BER` zeroed it → set.

**Root cause.** Existing Bear protection is narrow: `traditionalFollow`'s
`bearThreat` ([MonteCarloAgent+Traditional.swift:330], `opponentCanBearTrick`) only
guards the **dump-to-partner** path ("don't pile money onto a partner-winning trick
an opponent can Bear"). It does **not** cover:
- (a) the AI **winning a trick with its own high cards** while an opponent behind it
  holds the Bear — i.e. *when* to cash big money tricks so they don't sit under a
  live Bear;
- (b) the **endgame**, where the Bear is forced out on the last trick(s) and lands
  on whatever money is left there (the t13 case).
The bid valuation also gives the Bear a fixed EV (`HandEvaluator`, `case .bear`) and
doesn't model "opponents hold the Bear → my single biggest trick can be zeroed"
(variance — feeds Item 1). The **offense** side (`bearEnemy` role, Bear an enemy
money trick at effValue ≥ $10k) looks present; the gap is **defense**.

**Diagnose first.** Extend the diagnostic (cf. `testDiagnoseSkilledLeads`) to tally,
per hand, **money the AI captured that an opponent then Beared** — the HEURISTIC
FLAG already computes this — bucketed by trick and by whether `inference.isBearOut`
was true when the AI committed the money. That separates *avoidable* (cashed big
under a live Bear) from *unavoidable* (forced endgame).

**Candidate fixes (ranked).**
1. **Bear-aware big-trick timing (defense).** When `isBearOut` and an opponent who
   plays after me could hold it, don't stack my biggest money into a trick I'm
   winning — win cheaper, or defer. New legible role e.g. `.bearGuard` in
   `traditionalFollow` / the `PlayoutPolicy` follow path.
2. **Flush the Bear early.** As declarer, draw the Bear out onto a modest/own trick
   before cashing big side money (analogous to pulling trump). Principle: "Bear
   loose + I hold big side money → force it out first."
3. **Check the EndgameSolver.** Confirm `EndgameSolver` values the Bear correctly in
   its last-N-trick window. If the last-trick zeroing falls *outside* its gate
   (gate=2 ⇒ only the final 2 tricks), either extend the gate or add a heuristic:
   "don't leave big money for the last trick while the Bear is out."
4. **Valuation discount** for "opponents likely hold the Bear and my gross is
   concentrated in one big trick" (shared with Item 1).

**Validate.** Direct metric = "$ Beared against us / hand" from the diagnostic; drive
it down. Self-play A/B may catch *some* of this (MC opponents also Bear) + ladder
monotonicity; but a strong human times Bears better than MC, so weight the
diagnostic + handlog over win-rate. Confirm at ≥100.

---

### Shared notes
- Both items are **expert/skilled-relevant**; keep novice/casual capability-gated so
  the ladder stays monotone (`testTraditionalLadderMonotonicity`).
- Reuse the harness from v0.11.0: `testDiagnoseSkilledLeads` pattern (trace on →
  reconstruct hands → bucket), `runSelfPlay` A/Bs, `runBidCalibration`, handlog.
- Each lever should be a flag or capability so it stays A/B-able (house style).
