# Releases

## Normal workflow

1. Open a PR to `main`. Use `feat: description` for new functionality or `fix: description` for a bug fix. Optional scopes work too: `fix(chat): restore navigation`.
2. Wait for the required **Tests** check and resolve review conversations. CI validates the PR title and runs the checks listed in [Testing](testing.md).
3. Squash-merge with the PR title as the commit title. For a PR containing both features and fixes, use `feat:`.
4. The push to `main` runs **Tests** again. Only after success does **Release** calculate the version, build the app and widget, and publish the ZIP, `SHA256SUMS.txt` and signed `appcast.xml`.

| Squash title | Version change |
| --- | --- |
| `feat: …` / `feat(scope): …` | Next minor, reset patch: `1.4.2 → 1.5.0` |
| `fix: …` / `fix(scope): …` | Next patch: `1.4.2 → 1.4.3` |
| `docs:`, `refactor:`, `perf:`, `test:`, `build:`, `ci:`, `chore:`, `revert:` | Next patch |

Every merged PR produces a release, including maintenance. Branch commits do not each consume a version. Unsupported titles fail validation instead of guessing; `!`/automatic major releases are not supported by this minor/patch policy. Do not edit version numbers or create tags for normal releases.

## How versions are calculated

`.github/release.json` records the already-published `1.3.1` commit as the baseline. `Scripts/release_version.py` reads subsequent first-parent commit titles in order, applying the table above. The same commit always receives the same version, regardless of job completion order or retries. Keep this baseline fixed; no per-release changes are needed.

`Scripts/build_version.py` is the common source of bundle metadata for script builds, Xcode and the review catalogue. Release builds derive both version fields from the checked-out commit using `release_version.py`; the build number is the first-parent history length. There is no fallback version in `.xcconfig`, and conflicting manual version overrides fail the build. Xcode generates each target's Info.plist from this same calculation before processing it and verifies the result before signing.

Development/review builds use the nearest release tag on their first-parent history as the base version and display **Test build** in Settings. They also record the actual source commit and whether the working tree was modified. Intermediate branch commits do not pretend to be future published releases. Builds require full Git history and tags; release builds additionally require a clean working tree.

Before signing the feed, `release_artifacts.py` reads the app and widget metadata from the actual ZIP and compares their versions, build numbers, channel and source commit with the expected release identity. Before any publication mutation, it repeats that check and validates the checksum and appcast version/build/download URL/length. A stale ZIP cannot pass merely because the unpacked app beside it is correct. Missing, duplicate or inconsistent metadata stops publication.

To inspect the version of a checked-out main commit with full Git history:

```sh
python3 Scripts/release_version.py
```

The workflow uses GitHub's built-in token with `contents: write` only in the publishing job. PR jobs are read-only. Artifacts are Apple Silicon builds, ad-hoc signed without Developer ID notarization. Installation text comes from [release-notes.md](release-notes.md); GitHub generates change notes from merged PRs.

## Retry and repository settings

Use **Actions → CI → failed run → Re-run failed jobs**, or **Run workflow** on `main` for its current commit. Draft releases remain hidden until all three assets upload. A retry resumes a draft, leaves an already published release unchanged, and refuses to overwrite a tag pointing to a different commit. A later fix PR creates a new version; failed releases can leave gaps.

The repository uses squash merging with **PR title** as the default commit title. Protected `main` requires the up-to-date **Tests** check, a PR and resolved conversations; direct/force pushes are blocked, including for administrators. No second-person approval is required. These are repository settings, not enforced by workflow YAML; preserve them when transferring the repository or renaming checks.

## Signed app updates

Release builds set `LLM_UPDATE_CHANNEL=release`; local builds default to `development`. The stable feed URL is the latest release’s `appcast.xml` asset. `Scripts/sign_release.py` signs the ZIP and feed with Sparkle 2.10, verifies the archive against the public key embedded in the app, and verifies the previous feed before retaining up to 19 older items. Only an HTTP 404 is accepted for the first feed. Build numbers determine update order.

The Ed25519 public key is committed in `Configuration/UpdateSigning.xcconfig`. The private key is stored in the maintainer’s Keychain under account `llmusage-widget` and in the repository’s Actions secret `SPARKLE_PRIVATE_KEY`. CI sends the secret to Sparkle through stdin; it must never be committed or put in command arguments. A missing/mismatched key stops publication. Back up the Keychain key securely: existing installations trust this public key, so replacing it requires a deliberate signed migration. PR checks use disposable keys and do not access the production secret.

The application remains ad-hoc signed, without notarization. Ed25519 authenticates updates independently of Gatekeeper. The first release containing this updater still requires the usual manual installation; later releases update through the app. Signing the feed does not remove first-install Gatekeeper warnings.
