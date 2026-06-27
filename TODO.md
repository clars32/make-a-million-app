# Deferred work

## 1. Decompose the two oversized files — DONE (June 2026)

The project uses Xcode 16 file-system-synchronized groups, so new `.swift`
files in the source directories are picked up automatically — no
`project.pbxproj` changes were needed. Both types were split into same-type
`extension` files (public API unchanged):

- `MonteCarloAgent.swift` (1,900 → 170 lines): core struct/init/`chooseMove` +
  shared helpers. Phase clusters moved to `MonteCarloDifficulty.swift`,
  `MonteCarloAgent+Bidding.swift`, `MonteCarloAgent+TrickPlay.swift`,
  `MonteCarloAgent+Rollout.swift`.
- `GameView.swift` (1,485 → 382 lines): `GameBody`'s rendering moved to
  `GameView+Board.swift` and `GameView+Panels.swift`.

> NOT compile-verified in the authoring environment (no Xcode toolchain).
> Cross-file references were audited by hand (brace balance, method-name
> uniqueness, no cross-file `private` symbols, imports present). Run a build +
> the test suite to confirm before relying on it.

## 2. Split the `Difficulty` struct into shipped knobs + research levers

STILL DEFERRED. `MonteCarloAgent.Difficulty` carries ~30 fields, most of which
are default-off, A/B-gated research levers. Separating the shipped tuning knobs
from a nested `ResearchLevers` value would make the production decision path
easier to follow — but it ripples through ~30 lever mutations in
`AIArenaTests`/`BidEvalTests` that encode validated experiments (e.g.
`d.useISMCTS = true`, `exact.exactEndgameTricks = 4`). That churn on the A/B
harness must be done with the compiler and test suite available, so it is held
until then.
