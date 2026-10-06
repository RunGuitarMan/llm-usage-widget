# Releases

## Every PR chooses a version

1. Update `version` in `.github/release.json` manually. Use a plain `MAJOR.MINOR.PATCH`, for example `{"version": "1.6.0"}`. Choose any higher patch, minor or major version; PR titles no longer affect it.
2. The version must be **strictly greater than the current `main` version**. This applies to every PR, including documentation, refactoring and CI changes. An unchanged, lower, missing or malformed version fails the required **Tests** check.
3. If another PR merges first, update your branch from `main`, resolve the version file and rerun checks. Two PRs cannot merge with the same version. Keep the required check's **Require branches to be up to date before merging** setting enabled.
4. Squash-merge after **Tests** passes and review conversations are resolved. The push runs checks again, including the increase against the previous main commit. **Merging never publishes a release.**

For example, merge PRs carrying `1.5.1`, `1.5.2` and `1.6.0`, then publish just `1.6.0`. The intervening numbers need not have GitHub releases. Do not create release tags manually.

Choose the version once per PR, not once per commit. Follow-up commits in that PR keep the chosen version unless `main` catches up with or overtakes it. Major, minor and patch changes are all manual choices; there are no required title prefixes.

The first PR introducing this policy can compare with the old automatic version configuration on `main`. That compatibility code is only used to validate the migration; builds require the explicit `version` field.

## Publish when ready

Open **GitHub → Actions → Release → Run workflow**, leave branch **main** selected, and click **Run workflow**. No version input or manual tag is needed.

The workflow fixes the source commit at dispatch time, reruns the full CI checks for that commit, reads its repository version, builds the final app and widget once, runs normal/review window checks against that signed artifact, verifies its manifest again, then signs the update archive/feed and publishes:

- Git tag `vMAJOR.MINOR.PATCH` and a GitHub Release with generated change notes covering the accumulated PRs.
- `LLM-Usage-vMAJOR.MINOR.PATCH-macOS-arm64.zip`.
- `SHA256SUMS.txt` and signed `appcast.xml`.

The separate **CI** workflow runs checks on PRs and pushes to `main`; it has no publication job. **Release** has only a manual `workflow_dispatch` trigger and runs only for `main`. Calling CI manually also runs checks only. Release publications are serialized, and an older or equal new release is rejected against the latest published release. The signed feed additionally requires both the app version and build number to increase.

If more PRs merge while the release is running, they remain for the next manual release: the running build continues using its original commit. A stale queued run cannot downgrade the latest release. The workflow uses GitHub's built-in token with `contents: write` only in the publishing job; test jobs remain read-only.

## One repository version for every build

`.github/release.json` is the only source of the application's visible version (`CFBundleShortVersionString`). `Scripts/build_version.py` supplies it unchanged to script builds, Xcode, the widget and the review catalogue. Local and review builds use the current file too, even before that version is released; they display **Test build** and record the actual source commit and working-tree changes.

The separate internal build number (`CFBundleVersion`, used by Sparkle to order updates) remains the first-parent Git history length. It is deterministic for each commit and increases as PRs merge into `main`. It is not a second manually maintained version.

There is no fallback version in `.xcconfig` or from release tags. Conflicting `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` overrides fail the build. Xcode generates each target's Info.plist from the shared version code and verifies it before signing. Builds require full Git history; release builds also require a clean working tree.

Before signing and again before publishing, `release_artifacts.py` reads the app and widget metadata inside the actual ZIP and checks the version, build number, channel and source commit against the repository. It also verifies the checksum and the appcast's version/build/download URL/length. Missing, duplicate or stale metadata stops publication.

Inspect or validate the selected version locally:

```sh
python3 Scripts/release_version.py
python3 Scripts/release_version.py --check-increase origin/main
```

## Retry and repository settings

For a failed manual release, use **Actions → Release → failed run → Re-run failed jobs**, or start **Release** again on `main`. Draft releases stay hidden until all assets upload. A retry resumes a draft; an already published version at the same commit is a no-op. An existing tag pointing at another commit is never overwritten. A stale draft below the latest release is not published.

The repository uses squash merging. Protected `main` requires the up-to-date **Tests** check, a PR and resolved conversations; direct/force pushes are blocked, including for administrators. No second-person approval is required. These are repository settings, not workflow YAML; preserve them when transferring the repository or renaming checks.

Artifacts are Apple Silicon builds, ad-hoc signed without Developer ID notarization. Installation text comes from [release-notes.md](release-notes.md).

## Signed app updates

Release builds set `LLM_UPDATE_CHANNEL=release`; local builds default to `development`. The stable feed URL is the latest release’s `appcast.xml` asset. `Scripts/sign_release.py` signs the ZIP and feed with Sparkle 2.10, verifies the archive against the public key embedded in the app, and verifies the previous feed before retaining up to 19 older items. Only an HTTP 404 is accepted for the first feed. Build numbers determine update order.

The Ed25519 public key is committed in `Configuration/UpdateSigning.xcconfig`. The private key is stored in the maintainer’s Keychain under account `llmusage-widget` and in the repository’s Actions secret `SPARKLE_PRIVATE_KEY`. The manual **Release** workflow sends the secret to Sparkle through stdin; it must never be committed or put in command arguments. A missing/mismatched key stops publication. Back up the Keychain key securely: existing installations trust this public key, so replacing it requires a deliberate signed migration. PR checks use disposable keys and do not access the production secret.

The application remains ad-hoc signed, without notarization. Ed25519 authenticates updates independently of Gatekeeper. The first release containing this updater still requires the usual manual installation; later releases update through the app. Signing the feed does not remove first-install Gatekeeper warnings.
