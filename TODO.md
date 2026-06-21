# Deferred work

Tracked follow-ups that were intentionally left out of the codebase-review
cleanup because they need an Xcode build to land safely (new source files must
be registered in `project.pbxproj`, and the second item touches the test
targets). Do these in an environment where the project can be compiled.

## 1. Decompose the two oversized files

- `Make-A-Million/AI/MonteCarloAgent.swift` (~1,900 lines): split by phase into
  separate files/extensions — bidding, widow discard + trump, trick-play
  shortlist, and rollout/scoring.
- `Make-A-Million/Views/GameView.swift` (~1,500 lines): break into subviews.

Both require adding files to the Xcode project (`project.pbxproj`); verify the
project still opens and builds after registering them.

## 2. Split the `Difficulty` struct into shipped knobs + research levers

`MonteCarloAgent.Difficulty` carries ~30 fields, most of which are default-off,
A/B-gated research levers. Separate the shipped tuning knobs from a nested
`ResearchLevers` value so the production decision path is easier to follow.
This touches ~40 call sites across `MonteCarloAgent`, `AIArena`, and several
test files, so it must be done with the compiler available.
