# Implementation Plan — Traditional / Adaptive AI

Status: design agreed, not yet implemented. This document is the build spec.
It must be carried out in an environment where the Xcode project compiles and
the test suite runs (new source files must be registered in
`Make-A-Million.xcodeproj/project.pbxproj`, and several test targets change).

---

## 1. Problem and goal

The current AI plateaus on strength and, more importantly, draws the recurring
complaint that it *"doesn't play like a good player"*. Diagnosis (agreed): the
dominant failure is **defensible-but-illegible** moves — the search picks a
play that survives post-hoc analysis but runs contrary to what a human at the
table expects, both as a partner and as an opponent.

Root cause, structurally:

1. On the strong tiers, `MonteCarloAgent.Difficulty.searchAllLegalMoves` is on,
   which **bypasses `trickShortlist` entirely** (`if difficulty.searchAllLegalMoves
   && !forceNarrow { return legal }`). The shortlist is where the human
   principles live, so on exactly the tiers users care about, principles do not
   govern selection — every legal card is graded purely on rolled-out mean
   team-net.
2. The objective (mean team-net over **determinized worlds in which partner is
   modeled as a bot**) is misaligned with "good human partner". PIMC strategy
   fusion (rollouts see hidden cards) further over-credits clever-looking
   deviations.

Goal:

- **Traditional** (the entire shipped difficulty ladder): plays *intelligibly*
  at every skill level — every move has a nameable principled reason. Skill
  rises by **capability depth** (more principles, deeper table-reading, planning
  ahead), never by random error. The top tier plays like a strong human and is
  genuinely hard.
- **Adaptive** (a separate, expert opt-in side-door): the current search stack,
  free to explore unconventional, possibly-stronger lines. Reached deliberately,
  not by dragging difficulty up.

Two design decisions locked in:

- **Weakness is reduced capability, not injected error.** Drop `blunderRate` as
  the strength lever. A weak tier makes *understandable* mistakes (misses a
  subtle principle, doesn't count cards), which is exactly what makes it a
  teaching tool.
- **Tiebreak is lightly randomized among truly-equally-principled options
  only.** Randomization is the *last* step, over a residual that no principle can
  separate. It can never override a principle or a fork judgment.

---

## 2. The model

### 2.1 The unified ladder (Traditional), by capability depth

Each rung adds a nameable skill a human would also learn next.

| Tier | Principles | Inference | Plans ahead | Skill it adds |
|---|---|---|---|---|
| **Novice** | core: follow, take cheap, shed low, dump money to partner | current-trick winner only | no | the basics |
| **Casual** | + don't waste big money, Bear enemy money, bank when winning last | + void tracking | no | basic defense & money sense |
| **Skilled** | + preserve controllers, $40k on a virgin suit, pull trump as declarer | + highest-out / trump counting / widow-lock | light, at clear forks | positional play & counting |
| **Expert** | full: bear-threat, Bull-double, void-creation, establishment duck, over-trump-aware partner reads, specials sequencing | full: + count-exhaustion | yes, bounded, at forks | the complete strong-human game |

Strength rises by *adding tools*. Every tier is 100% legible by construction —
every move it plays has a named reason at every level.

### 2.2 Adaptive (off the ladder)

A separate opt-in, conceptually above Expert but presented as a *different kind*
of play, not "Expert + 1". Inherits today's search machinery: full-width MCTS /
PIMC, `EndgameSolver`, optional `ISMCTS`, `rolloutBidEval`, `matchWinWeight`, the
research levers. UI must label it distinctly (e.g. "Adaptive — experimental")
and not place it on the main difficulty slider.

### 2.3 "Truly equally-principled" (the randomization rule)

Define a **principled key** for a candidate move and randomize uniformly only
within the best key-group; otherwise the key decides deterministically.

Backbone is the existing `MonteCarloAgent.tiePreference`:

```
tiePreference(c, trump, bankToOwnTeam) = (specialClass, moneyTerm, isTrump, rankOf)
```

Split it:

- **Principled key** (a human notices these → deterministic):
  `(specialClass, moneyDirection, isTrump, isController)`
  where `moneyDirection` is `tiePreference`'s `moneyTerm` (bank `-value` when our
  team is safely taking the trick, else commit `+value`), and `isController` is
  *"this card is the top of its effective color in my hand"* (from
  `topOfEachColorInMyHand` / `PlayoutPolicy.topOfEachColorInHand`). Adding
  controller-ness prevents randomly burning a future controller against a junk
  card.
- **Residual** (interchangeable → randomizable): pure `rankOf` among cards in the
  same tier. Throwing the 2 vs the 3 of a dead side suit is the canonical true
  tie.

Procedure:
1. Group the decisive candidate set by principled key.
2. Take the best key-group (lowest tuple, compared lexicographically as
   `tiePreference` already does).
3. If that group has one member → play it (deterministic).
4. If ≥2 members → randomize uniformly **drawing from the agent's existing
   `seedBox`** (not a fresh RNG), so `(seed, position) → same move` and replays /
   self-play stay reproducible.

Equality is **structural** (same key), never an EV near-tie window — Traditional
has no full-set MCTS score to threshold, and an EV window would smuggle the noise
problem back in. The current `tieEps = 20_000` window is an Adaptive-only concept
and stays there.

### 2.4 Selection order in Traditional (three layers)

1. **Principle decides** — most positions collapse to one decisive candidate.
   Play it, no search.
2. **Genuine fork** — ≥2 candidates carry *different, each-valid* principles
   (duck vs cash; cheap-win vs Tiger-smash; which suit to establish). Resolve by
   a bounded search **confined to that co-principled set** (never
   `searchAllLegalMoves`). At tiers with `plansAhead == false`, resolve the fork
   by deterministic shortlist priority instead. The more forks resolved by an
   explicit principle (e.g. `establishmentDuck`'s "duck with length ≥3 behind the
   boss"), the less search Traditional needs.
3. **True tie** — §2.3 randomization over the residual.

---

## 3. Architecture changes

### 3.1 Reshape `MonteCarloAgent.Difficulty`

This subsumes TODO item #2 ("split `Difficulty` into shipped knobs + research
levers"). Target shape:

```swift
nonisolated struct Difficulty {
    enum Style { case traditional, adaptive }
    var style: Style

    // ── Traditional capability ladder (used when style == .traditional) ──
    enum PrincipleLevel: Int, Comparable { case core, cooperative, positional, complete }
    enum InferenceLevel: Int, Comparable { case none, voids, counting, deep }
    struct Capabilities {
        var principles: PrincipleLevel
        var inference: InferenceLevel
        var plansAhead: Bool          // bounded search at genuine forks
        var forkSamples: Int          // worlds per fork when plansAhead (e.g. 12–20)
    }
    var capabilities: Capabilities

    // ── Adaptive search + research levers (used when style == .adaptive) ──
    // The CURRENT Difficulty fields move here verbatim, grouped:
    struct Adaptive {
        var samples: Int
        var trickCandidates: Int
        var bidLeanStrength: Double
        var searchAllLegalMoves: Bool
        var exactEndgameTricks: Int
        var rolloutExactTricks: Int
        var useISMCTS: Bool
        var ismctsBudgetMultiplier: Int
        var ismctsShortlistRoot: Bool
        var matchWinWeight: Double
        var rolloutBidEval: Bool
        var bidRolloutWorlds: Int
        var bidMakeProbability: Double
        var bidRolloutLean: Bool
        var bidRolloutDropAggression: Bool
        var bidAggression: Double
        var partnerRespect: Double
        var matchAwareness: Double
        var deduceWidowHoldings: Bool
        var declarerTrumpBias: Double
        var filterDominatedDonation: Bool
        var filterBearDecline: Bool
        var playHistoryWeighting: Double
        var rolloutCommandingPull: Bool
        var rolloutSpecialEscape: Bool
        var rolloutTopPull: Bool
        var rolloutEstablishDuck: Bool
        var rolloutBankWin: Bool
        var calibratedValuation: Bool
        // … plus the existing computed helpers (evaluatorTables, playConsistencyFilter)
    }
    var adaptive: Adaptive
}
```

Notes:
- `blunderRate` is removed as a difficulty lever. (Optionally keep a single
  vestigial field defaulting to 0 if playtests later want a touch of human
  inconsistency, but it is NOT how the ladder gets weaker.)
- The four Traditional tiers are **fixed presets**, not free-form flag combos.
  Capability levels are coupled (e.g. `.positional` principles need
  `.counting` inference for `iControlColor`); presets keep them consistent. The
  individual flags stay independently settable so tests / A-Bs can probe combos.
- Bidding knobs that still matter to Traditional (`bidAggression`,
  `partnerRespect`, `matchAwareness`) can either live in a small shared block or
  be derived per tier. Simplest: keep them in `Adaptive` and have Traditional
  read sensible fixed values (see §4.4).

### 3.2 Player-facing `Difficulty.Level`

Replace `easy/normal/hard/extreme` with the ladder + adaptive:

```swift
enum Level: String, Codable, CaseIterable, Identifiable, Sendable {
    case novice, casual, skilled, expert   // the Traditional ladder (slider)
    case adaptive                          // off-ladder expert side-door

    static let ladder: [Level] = [.novice, .casual, .skilled, .expert]
    var isAdaptive: Bool { self == .adaptive }
    var profile: Difficulty { … }          // maps each case to a preset
    var displayName: String { … }
    var blurb: String { … }
}
```

The settings slider iterates `Level.ladder`; Adaptive is a separate toggle
(§6).

### 3.3 Capability matrix (preset definitions)

| | principles | inference | plansAhead | forkSamples |
|---|---|---|---|---|
| novice | core | none | false | — |
| casual | cooperative | voids | false | — |
| skilled | positional | counting | true | 12 |
| expert | complete | deep | true | 20 |
| adaptive | (n/a — uses search) | deep | (n/a) | — |

---

## 4. Phased implementation

Land in order; each phase compiles and keeps tests green.

### Phase 0 — Baseline & safety net
- Run the existing test suite and `AIArena.run(matches:difficulty:.normal)` to
  capture a pre-change baseline number.
- Tag/branch so the current behaviour is recoverable.

### Phase 1 — Data-model split (no behaviour change yet)
- Introduce the `Difficulty` shape in §3.1, moving today's fields under
  `adaptive`. Define `style`, `capabilities`.
- Build the five presets and rewrite `Level` (§3.2). Map the **old** behaviour
  onto a temporary `adaptive` preset so nothing changes functionally yet.
- Update all call sites that read the old flat fields
  (`difficulty.samples`, `difficulty.searchAllLegalMoves`, etc.) to
  `difficulty.adaptive.*`. Search the repo for each field name.
- Update tests that construct `Difficulty(...)` directly
  (`AITacticsTests`, `BidEvalTests`, `EndgameSolverTests`, `ISMCTSTests`,
  `PlayConsistencyTests`, `AgentTests`, `AIArenaTests`, `PolicyMiner`,
  `AIArena`). Provide a `Difficulty.adaptiveResearch(...)` convenience
  initializer so test levers stay ergonomic.
- **Compiles + all tests pass before moving on.**

### Phase 2 — Route by style in `chooseMove`
- In `MonteCarloAgent`, branch the trick-play (and bidding) paths on
  `difficulty.style`:
  - `.adaptive` → existing `decideTrickPlay` / `decideBid` unchanged (now reading
    `difficulty.adaptive.*`).
  - `.traditional` → new `decideTrickPlayTraditional` / `decideBidTraditional`
    (Phases 3–4).
- Keep `.adaptive` as the only wired tier initially so Phase 2 is a pure
  refactor with a behaviour-preserving default.

### Phase 3 — Traditional trick play (the core)
New `decideTrickPlayTraditional(view:legal:)`:

1. Build `TableInference` **gated by `capabilities.inference`** (Phase 3a).
2. Build the **decisive** shortlist gated by `capabilities.principles`
   (Phase 3b) — this returns candidates already annotated with their principled
   role so forks vs true-ties are distinguishable.
3. Apply the selection order §2.4:
   - one decisive candidate → play it;
   - genuine fork + `plansAhead` → bounded PIMC over *only* those candidates
     (reuse `evaluateWorld`, `capabilities.forkSamples` worlds, **shortlist as the
     sole candidate set**, never `searchAllLegalMoves`); fork without
     `plansAhead` → shortlist priority;
   - residual true ties → §2.3 randomization via `seedBox`.
4. Record to `AIDecisionTrace` with the named reason for the chosen branch
   (reuse `tracePlayNotes` / `shortlistNote`), so legibility is auditable.

**Phase 3a — Gate `TableInference` by level.** Replace the `deepInference: Bool`
init parameter with `inference: Difficulty.InferenceLevel`. Inside, gate:
- `.none`: voids dictionary stays empty; `highestOutInColor`, `iControlColor`,
  `knownDeclarerHoldings`, trump-count queries return the conservative
  "unknown" answer (nil / false / 0). Only `currentWinner`/`partnerWinning` work.
- `.voids`: enable failed-follow void inference.
- `.counting`: enable `stillOut`, `highestOutInColor`, `iControlColor`,
  `trumpStillOutInOpponentsAndPartner`, widow-lock (`knownWidowInDeclarer`),
  `opponentCanBear/BullTrick`.
- `.deep`: additionally enable count-exhaustion voids (today's `deepInference`
  block).
Update the single existing call site (`decideTrickPlay`) and the Adaptive path
to pass `.deep`. Update `MonteCarloAgentTests`/`AITacticsTests` references.

**Phase 3b — Layer the shortlist by principle and make it decisive.**
Refactor `leadShortlist` / `followShortlist` so each principle is guarded by a
`capabilities.principles` threshold, and have them return a small **ordered,
role-tagged** candidate list (not a wide net for MCTS). Mapping of existing
branches to levels:

- **core** (all tiers): `followShortlist` cheapest-winner (section B, the
  `cheap` pick) and `cheapShed` default (section D); `leadShortlist`
  `lowSafeLead` (5) and last-resort (6); basic partner money-dump (section A
  highest-money dump, *without* controller preservation or bear-threat).
- **cooperative** (≥ casual): "don't waste big money" (preserve nothing yet, but
  prefer smallest money), Bear on enemy money trick (section C with the simple
  `effValue >= 10_000` gate), bank money when last-to-play (the `amLastToPlay`
  bank in section B).
- **positional** (≥ skilled): controller preservation (`nonControllers` filter in
  section A), `$40k` virgin-suit lead (leadShortlist 2), sure-lead non-trump
  (leadShortlist 3 / `sureLeadNonTrump`), pull-trump-as-declarer (leadShortlist
  1), cash-high-trump-when-pulled (leadShortlist 4), cheapest-vs-biggest winner
  fork (section B `cheap` + `big`).
- **complete** (expert): bear-threat money safety (`opponentCanBearTrick`),
  Bull-double awareness (`opponentCanBullTrick`, `bullIsCostly`), `voidCreatingShed`,
  Bull-escape candidates, specials rescue, full `canBeOverturned` partner-safety
  judgment, establishment duck fork.

Where a branch currently emits multiple candidates "for MCTS to choose"
(section B `cheap` + `big`; the win-cheap-vs-bank tension), tag them as a
**fork** at `positional`+ (resolved by bounded search if `plansAhead`, else by
priority: prefer `cheap`/conserve). Where two candidates differ only by residual
rank, they are **true ties**.

Implement a `principledKey(_ card, context) -> (Int,Int,Int,Int)` helper (§2.3)
and a `chooseAmongPrincipled(_ candidates:)` that does group → best-group →
deterministic-or-randomize. `tiePreference` is refactored to expose the key
prefix so the two share one definition.

### Phase 4 — Traditional bidding / discard / trump / misdeal
- `decideBidTraditional`: use `HandEvaluator.bestValuation` (scalar
  `expectedGross`) with **no** rollout bid eval (that is an Adaptive feature).
  Keep the legible rules already in `decideBid`: bid the minimum legal raise,
  defer to partner per `partnerRespect`, match-awareness ceiling, forced-opener
  minimum. These are already principle-shaped; reuse them.
  - Tie bidding strength to tier modestly via `HandEvaluator.Tables`
    (`.calibrated` for skilled/expert, `.original` or a slightly conservative
    read for novice/casual) and/or a per-tier `bidAggression`/`partnerRespect`.
    Keep it simple — bidding is not the main complaint.
- `decideDiscard`, `decideTrump`: already heuristic and legible; reuse as-is
  (they don't go through MCTS). Gate `evaluatorTables` by tier.
- `decideMisdeal`: unchanged (already principle-based).

### Phase 5 — Adaptive wiring
- Map `Level.adaptive.profile` to a `style: .adaptive` preset carrying today's
  strongest validated settings (Hard/Extreme-equivalent: `searchAllLegalMoves`,
  `exactEndgameTricks: 2`, `rolloutTopPull`, `calibratedValuation`,
  `matchWinWeight: 400_000`, `rolloutBidEval`, `deepInference`/`.deep`). Decide
  whether Adaptive also turns on `useISMCTS` (validated +8pp on Normal-profile,
  neutral on Extreme — likely leave off by default; it remains A-B-able).
- Confirm the Adaptive trick path still bypasses the shortlist (full-width) as
  today; that is correct and intended for this mode.

### Phase 6 — Settings & UI (see §6).

### Phase 7 — Validation & tests (see §7).

---

## 5. File-by-file touch list

- `Make-A-Million/AI/MonteCarloAgent.swift`
  - `Difficulty` reshape (§3.1), `Level` rewrite (§3.2), presets (§3.3).
  - New `decideTrickPlayTraditional`, `decideBidTraditional`,
    `chooseAmongPrincipled`, `principledKey`; refactor `tiePreference` to share
    the key.
  - `trickShortlist`/`leadShortlist`/`followShortlist` gated by principle level
    and made decisive (Phase 3b).
  - Route `chooseMove` by `style`.
  - (Optional, TODO #1) split this ~1,900-line file along phase boundaries
    (bidding / discard+trump / trick shortlist / rollout+scoring) into
    extensions or separate files — **requires `project.pbxproj` registration**.
- `Make-A-Million/AI/TableInference.swift`
  - `init(view:inference:)` replacing `deepInference: Bool`; gate queries by
    level (Phase 3a).
- `Make-A-Million/AI/PlayoutPolicy.swift`
  - No change for Traditional (only the bounded-fork search and the Adaptive
    path use it). Rollout flags continue to be driven from `difficulty.adaptive`.
- `Make-A-Million/AI/AIWorld.swift`, `ISMCTS.swift`, `EndgameSolver.swift`
  - No logic change; only call sites that read moved `Difficulty` fields.
- `Make-A-Million/AI/AIArena.swift`, `PolicyMiner.swift`
  - Update `Difficulty` construction; add monotonicity / legibility instruments
    (§7).
- `Make-A-Million/Views/DebugFlags.swift` (`GameSettings`, `SettingsView`)
  - `aiDifficulty` persistence migration; slider over `Level.ladder` + Adaptive
    toggle; updated `blurb`s (§6).
- `Make-A-Million/Views/GameSession.swift`, `Agents/Networking/NetSession.swift`
  - No change beyond `botDifficulty` continuing to resolve from
    `aiDifficulty.profile`.
- Tests: `AgentTests`, `AITacticsTests`, `BidEvalTests`, `EndgameSolverTests`,
  `ISMCTSTests`, `PlayConsistencyTests`, `AIArenaTests` — update `Difficulty`
  construction and any `.normal/.extreme` level references; add new Traditional
  tests (§7).

---

## 6. Settings & persistence

- Persisted key `settings.aiDifficulty` stores `Level.rawValue`. The old values
  (`easy/normal/hard/extreme`) will no longer decode. Add a **migration** in
  `GameSettings.init`:
  - `easy → novice`, `normal → casual` (or `skilled`), `hard → skilled`,
    `extreme → expert`. Map old `extreme` to `expert` (Traditional), NOT to
    `adaptive` — nobody should be silently moved into the experimental mode.
  - Unknown/!decodable → default `.skilled` (a strong-but-legible default that
    matches "most people just want to play"). Confirm the default tier with a
    playtest; `.casual` or `.skilled` are both reasonable defaults.
- `SettingsView.difficultySection`:
  - Slider binds over `Level.ladder` (four positions) instead of `allCases`.
  - Add an **Adaptive toggle** below the slider, footer: "Experimental. The AI
    explores unconventional, sometimes stronger lines — for players who already
    beat Expert." When on, `aiDifficulty = .adaptive` and the slider is disabled
    (it remembers the last ladder tier for when Adaptive is turned back off).
  - Rewrite each tier `blurb` to describe the *capability* it adds (mirroring the
    §2.1 table), since that is now what the player is choosing.
- Keep `rulesLocked` behaviour (difficulty frozen mid-hand) as-is.

---

## 7. Validation & acceptance criteria

The yardstick changes for Traditional. Self-play "beats the old champion" is the
**wrong** metric here; build these instead.

1. **Legibility (hard gate).** With `logHandsToFile`/`AIDecisionTrace` enabled,
   every Traditional trick decision must carry a nameable principled branch and
   no move outside the principled candidate set. Add a test that plays N seeded
   hands at each Traditional tier and asserts: for every recorded `PlayDecision`,
   the chosen card equals the decisive principled pick OR a member of a true-tie
   group (never an unexplained move). Target: 100% by construction.
2. **Monotonicity.** Add `AIArena` paired runs `novice < casual < skilled <
   expert` (each tier beats the one below over many seeded matches, seats
   swapped). Acceptance: each higher tier wins > ~55% head-to-head. This proves
   the ladder is a real ladder.
3. **Expert calibration.** Expert vs a strong baseline (e.g. Adaptive, or a
   fixed reference): Expert should be respectable (target set-rate comparable,
   win-rate not collapsing) without needing to *win* — it is allowed to lose to
   Adaptive's deeper search. Record the number; it is a tracking metric, not a
   pass/fail.
4. **Reproducibility.** A test that the same `(seed, position)` yields the same
   Traditional move across runs (randomization draws from `seedBox`).
5. **No-regression on Adaptive.** Re-run the existing Adaptive (ex-Hard/Extreme)
   A-B tests; numbers should match the Phase-0 baseline since that path is
   unchanged.
6. **Human playtest** is the final judge of "feels like a sensible partner".
   Recruit the complainants; check the specific hands they flagged now play the
   expected move at `skilled`/`expert`.

Also: re-run a `PolicyMiner` pass against the **Traditional** policy — it now
mines disagreements between the principled policy and a 1-ply improvement, which
surfaces principles that are still locally inconsistent (candidates to promote
into the shortlist) rather than rollout misplays.

---

## 8. Risks & open questions

- **Shortlist completeness.** Traditional is only as good as the encoded
  principles. If `expert` is not actually "strong human", the gap is a missing
  principle, found via PolicyMiner + flagged hands — additive work, not a redesign.
- **Fork classification.** The line between "genuine fork" (search) and "true
  tie" (randomize) must be drawn by the principled key, not by EV. Getting the
  key wrong is the main way confusion could leak back in. Unit-test the key on
  the handlog examples already cited in `MonteCarloAgent` comments (e.g. "Y$30
  over Y$40", "G$40 over G$5").
- **Default tier choice.** `.skilled` vs `.casual` as the shipped default —
  resolve by playtest. "Most people just want to play" argues for a strong-ish
  but unmistakably legible default.
- **Adaptive-as-partner.** Even improved, Adaptive next to a human partner is
  unconventional by design. The "experimental / opt-in" framing must be explicit
  in the UI so this is a choice, not a surprise. (Per-seat modes — Traditional
  partner + Adaptive opponents — are out of scope but the `Level` data model does
  not preclude them later.)
- **`project.pbxproj`.** Any new `.swift` files (capability types, split-out
  extensions) must be registered, and the project must be confirmed to still open
  and build. Prefer adding types to existing files first to minimize pbxproj risk;
  do the TODO #1 decomposition as a separate, clearly-scoped commit.

---

## 9. Out of scope (future)

- IS-MCTS promotion decisions (stays an Adaptive A-B lever).
- Per-seat mode selection (partner vs opponents).
- World-sampling / estimator research to push the Adaptive plateau (separate
  track; this plan does not touch it).
- Any change to the engine, rules, or the `PlayerView` projection.

---

## 10. Suggested commit sequence

1. `Difficulty` data-model split + `Level` rewrite + call-site/test updates
   (behaviour-preserving; everything still routes through the Adaptive path).
2. `chooseMove` style routing.
3. `TableInference` level gating.
4. Decisive, layered Traditional shortlist + `principledKey` +
   `chooseAmongPrincipled`.
5. Traditional bidding/discard/trump.
6. Adaptive preset finalization.
7. Settings UI + persistence migration.
8. Validation instruments + new tests.
9. (Optional) `MonteCarloAgent` file decomposition (TODO #1).
