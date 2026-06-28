---
description: Cut a new release — draft the What's New entry, bump the version, commit, tag, and push.
argument-hint: "[version | major | minor | patch]  (optional, e.g. 0.10.0 or minor)"
---

You are cutting a new release of Make-A-Million. The canonical process is in
`RELEASING.md` — follow it. Use the user's optional argument: `$ARGUMENTS`.

Work in order. Do NOT run the irreversible steps (commit / tag / push) until the
user approves the plan in step 5.

## 1. Gather context (run these)
- `git describe --tags --abbrev=0` — the last released version/tag.
- `git log <last-tag>..HEAD --oneline` and `git status --short` — everything
  changed since the last release, committed and uncommitted.
- Read the top of `Make-A-Million/Views/WhatsNew.swift` for the current highest
  `seq` and the `ReleaseNote` format.

## 2. Decide scope
The release commit should contain the finished feature plus the version +
changelog bump. If the working tree has unrelated or unfinished changes, DO NOT
sweep them in — list them and ask the user which files belong in this release.
(A separate in-progress feature must be excluded; this has happened before.)

## 3. Pick the version
- If `$ARGUMENTS` is a semver (e.g. `0.10.0`), use it.
- If it's `major` / `minor` / `patch`, bump the last tag accordingly.
- If empty, infer from the changes and recommend: new feature → minor, fixes
  only → patch, breaking change or first public launch → major. We're pre-1.0
  beta, so stay on `0.x` until the user decides to launch 1.0.0.

## 4. Draft and confirm
Draft a new `ReleaseNote` for the top of `Changelog.releases`:
`seq` = current max + 1, `version` = chosen version, `date` = today (format like
"Jul 5, 2026"), a short player-facing `title`, and a one-to-two-sentence
`summary`. Player-facing language, not commit jargon. (No build number — Xcode
Cloud owns those and they aren't listed per entry.)

Show the user: the version, the files in scope, and the drafted entry. **Wait
for approval or edits.** (If the invocation explicitly said to skip
confirmation, you may proceed.)

## 5. Execute on approval
- Insert the `ReleaseNote` into `WhatsNew.swift`.
- Bump the marketing version by editing `MARKETING_VERSION` (both app-target
  configs) in `Make-A-Million.xcodeproj/project.pbxproj`. Do NOT use
  `agvtool new-marketing-version` (it misbehaves with this project's generated
  Info.plist). Do NOT touch the build number — Xcode Cloud assigns it.
- Stage exactly the agreed files (feature + `WhatsNew.swift` +
  `project.pbxproj`); re-check `git status` matches the scope.
- Commit with a clear message ending in:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- `git tag -a v<version> -m "<title>"`
- `git push origin main && git push origin v<version>`

## 6. Report
State what shipped: version, tag, and that Xcode Cloud will build, assign the
build number, and upload it to TestFlight.
