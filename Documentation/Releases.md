# CI and releases

Every pull request to `main` runs the **Tests** job on an Apple Silicon macOS 26 runner with Xcode. It runs Swift XCTest, the portable regression suite, native menu and icon checks, app/widget typechecking, a complete app build with bundle/signature validation, and Python tests of the release version calculation. These checks use fixtures, not private CLI logs or signing credentials.

`main` requires a pull request, a successful **Tests** check for the current base, and resolved review conversations. These rules also apply to administrators. Direct pushes, force pushes and branch deletion are blocked. No second-person approval is required, so the owner can merge their own PR after CI passes. Squash merging keeps one main commit per PR.

After each merge, the same workflow checks the resulting `main` commit and publishes a release only if **Tests** passes. The first release was **v1.0**. The current release line starts at **v1.3.1**, followed by **v1.3.2**, **v1.3.3**, etc. Documentation-only PRs also produce a release. No manual tags, version commits, personal access tokens or external release service are needed; the publishing job uses GitHub's built-in token with `contents: write`. PR jobs have read-only access, including those from forks.

Each release contains an ad-hoc signed `LLM Usage.app` with its embedded widget in an Apple Silicon ZIP, a SHA-256 checksum, and generated change notes. The app and widget receive the release version and build number during packaging. These builds are not Developer ID signed or notarized; see the installation instructions in the README.

## Version calculation

`.github/release.json` stores the initial version and the commit immediately before the first release. `Scripts/release_version.py` counts commits along the first-parent history after that baseline. The first commit gets the base version; each later commit increments its patch number. This gives each merged PR its own deterministic version, even if builds complete out of order. Commits within a feature branch do not each consume a version when squash/merge commits are used.

The app's checked-in `MARKETING_VERSION` is the default for local development. Release builds override it from the calculated version; the build number is the count of first-parent commits. To start a new release line, change `base_version` and set `base_commit` to the current `main` SHA in the same PR. For example, `base_version: "1.3.1"` makes that PR's squash merge the `v1.3.1` release. Recheck the baseline if another PR merges first.

## Retrying a failed release

Use **Actions → CI → failed run → Re-run failed jobs**. Alternatively, **Run workflow** on `main` retries the current main commit. The same commit keeps its tag/version; an already published release is left unchanged. Uploads are completed while the release is a draft, and an interrupted draft can be resumed. An existing tag pointing at another commit causes failure rather than being overwritten. Fixing code in a new PR produces the next version, so a failed release can leave a harmless gap in the published version sequence.

The required check is named **Tests**. If renaming it, update the branch protection setting too. Branch protection is a GitHub repository setting, not something a workflow file can enforce by itself.
