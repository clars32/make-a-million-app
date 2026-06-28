# Releasing Make-A-Million

How versioning and releases work for this app.

## The two numbers

| | Build setting | Info.plist key | Who controls it |
|---|---|---|---|
| **Marketing version** | `MARKETING_VERSION` | `CFBundleShortVersionString` | **You** — semver, committed + git-tagged |
| **Build number** | `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | **Xcode Cloud** (automatic) |

**Marketing version** is the public semver users see, and the one that carries
meaning. You choose it: `MAJOR.MINOR.PATCH`.
- `PATCH` (`0.9.2`) — bug fixes only.
- `MINOR` (`0.10.0`) — new features, backward compatible.
- `MAJOR` (`1.0.0`) — the first public App Store launch, then breaking changes.

We're in **pre-release beta** (`0.x`). Bump toward `1.0.0` for the first public
App Store release.

**Build number** is owned by Xcode Cloud and is **not something we manage**.
Xcode Cloud overrides `CFBundleVersion` with its own automatic counter
(`CI_BUILD_NUMBER`) when it archives and submits to TestFlight — there is no
supported way to make it use a value from the project or a script. So:

- Don't try to set the build number in the repo. The committed
  `CURRENT_PROJECT_VERSION` only affects *local* builds; Xcode Cloud ignores it.
- The build number you see on a TestFlight build is Xcode Cloud's counter. It
  does **not** track the marketing version or the commit history, so we don't
  list per-release build numbers anywhere.
- To set the *starting* point, use **App Store Connect → your app → Xcode Cloud
  → Settings → Build Number**. It auto-increments from there.

The marketing version is the identifier for everything user-facing (the What's
New page keys on it).

## Cutting a release

The `/release` slash command does all of this for you (draft the What's New
entry, bump the version, commit, tag, push). Manually, the steps are:

1. **Add the What's New entry.** In `Make-A-Million/Views/WhatsNew.swift`,
   prepend a `ReleaseNote` to `Changelog.releases` with `seq` one greater than
   the current top entry, the new `version`, today's `date`, a short
   player-facing `title`, and a `summary`. This drives the in-app pop-up; see
   the file header for details.
2. **Bump the marketing version:** edit `MARKETING_VERSION` (both app-target
   configs) in `Make-A-Million.xcodeproj/project.pbxproj`, or change it in
   Xcode's target ▸ General ▸ Version field. Do NOT use
   `agvtool new-marketing-version` — it misbehaves with this project's
   generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`) and doesn't update
   the build setting.
3. **Commit** the feature + version bump together.
4. **Tag it:** `git tag -a v0.9.2 -m "<title>" && git push origin v0.9.2`.
5. **Push** to the branch Xcode Cloud watches. It builds, assigns the build
   number, and uploads to TestFlight.
6. Add **"What to Test"** notes in App Store Connect for the TestFlight build.

## Quick reference

```sh
# current marketing version (just grep the project)
grep -m1 MARKETING_VERSION Make-A-Million.xcodeproj/project.pbxproj
# bump it: edit MARKETING_VERSION (both app-target configs) in the pbxproj
git tag -a v0.10.0 -m "Release 0.10.0"          # tag the release commit
```

## Notes

- **Already-uploaded builds can't be relabeled.** A build's version and build
  number are baked into the binary; App Store Connect shows them as-is. Old
  TestFlight builds that shipped as `1.0` stay `1.0`. None of that is public
  history until the first App Store submission.
- Git tags (`v0.1.0` … ) are repo history only; they have no link to App Store
  Connect.
