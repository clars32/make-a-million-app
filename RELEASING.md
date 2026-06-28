# Releasing Make-A-Million

How versioning and releases work for this app. Two numbers, with very
different jobs.

## The two numbers

| | Build setting | Info.plist key | Who sets it | Example |
|---|---|---|---|---|
| **Marketing version** | `MARKETING_VERSION` | `CFBundleShortVersionString` | **You**, by hand, committed + tagged | `0.9.0` |
| **Build number** | `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | **Automatic** — git commit count | `51` |

**Marketing version** is the public semver users see. It carries meaning, so
you choose it: `MAJOR.MINOR.PATCH`.
- `PATCH` (`0.9.1`) — bug fixes only.
- `MINOR` (`0.10.0`) — new features, backward compatible.
- `MAJOR` (`1.0.0`) — the first public App Store launch, then breaking changes.

We're in **pre-release beta** (`0.x`). Bump toward `1.0.0` for the first public
App Store release.

**Build number** is an internal counter that must strictly increase with every
upload to App Store Connect. We never pick it by hand — it's derived from the
git commit count (`git rev-list --count HEAD`), so it rises on its own and is
the same locally and in CI.

## How the build number is wired

- The app target uses `VERSIONING_SYSTEM = apple-generic`, so `agvtool` can
  drive `CURRENT_PROJECT_VERSION`.
- On Xcode Cloud, `ci_scripts/ci_post_clone.sh` runs before each build and sets
  the build number to the commit count. **This is the number that ships.**
- The `CURRENT_PROJECT_VERSION` committed in the project is just a baseline for
  local builds. Refresh it anytime with `scripts/sync-build-number.sh`.

> **Xcode Cloud setting to check (one-time):** Xcode Cloud increments the build
> number by default. Our `ci_post_clone.sh` takes over instead. If you ever see
> the shipped build number *not* match the commit count, open the workflow in
> App Store Connect and make sure automatic build-number management is **off**
> so the script's value is used.

> **Caveat — same-commit rebuilds:** the build number is tied to the commit, so
> re-running a release build on the *same* commit produces the *same* build
> number, which App Store Connect rejects as a duplicate. Always land at least
> one new commit (even an empty `git commit --allow-empty`) before cutting a new
> upload.

## Cutting a release

1. **Add the What's New entry.** In `Make-A-Million/Views/WhatsNew.swift`,
   prepend a `ReleaseNote` to `Changelog.releases` with `seq` one greater than
   the current top entry. Set `build:` to the build number this will ship as
   (the commit count *after* you commit — or leave `nil` and fill it in once the
   build appears in App Store Connect). This is what drives the in-app pop-up;
   see the file header for details.
2. **Bump the marketing version** if this release warrants it:
   `xcrun agvtool new-marketing-version 0.9.1` (or edit `MARKETING_VERSION` in
   the project). Skip for a plain TestFlight iteration that isn't a new version.
3. **Commit** everything: `git commit -am "Release 0.9.1"`.
4. *(optional)* **Sync the local build number:** `scripts/sync-build-number.sh`,
   then commit, so local builds match what CI ships.
5. **Tag it:** `git tag v0.9.1 && git push --tags` (the build number is implied
   by the commit the tag points at).
6. **Push** to the branch Xcode Cloud watches. Xcode Cloud builds, sets the
   build number from the commit count, and uploads to TestFlight.
7. Add **"What to Test"** notes in App Store Connect for the TestFlight build.

## Quick reference

```sh
# Current numbers
xcrun agvtool what-marketing-version -terse   # marketing version
git rev-list --count HEAD                      # build number CI will ship

# Bump marketing version
xcrun agvtool new-marketing-version 0.9.1

# Sync committed build number to the commit count (optional, for local parity)
scripts/sync-build-number.sh
```
