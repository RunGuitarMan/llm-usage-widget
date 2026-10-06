# UI testing and debugging

Use one test application for every interactive UI check, automated window check and diagnostic experiment: `build/manual-review/LLM Usage.app`, built by `bash Scripts/manual-review.sh`.

- This build must use the production `LLMUsageApp`, `AppRootView`, scenes, toolbar and sheets. The catalogue supplies scenarios and synthetic external services.
- Run automated UI checks with `bash Scripts/check-windows.sh` (the same build with `--self-check`). Use `bash Scripts/manual-review.sh` for interactive review; Command-1 opens its catalogue.
- Add new scenarios, assertions and temporary diagnostics to the existing review mode under `MANUAL_REVIEW`. Inspect its actual windows and controls.
- Do not create or launch separate diagnostic apps, alternate app entry points, or manually hosted copies of product windows. This also applies to temporary experiments under `build/` or `/tmp`, including window-chrome and geometry investigations.
- Do not use a shipping or ordinary development app as a second UI test target. Building it to verify packaging, signatures and the absence of review code is fine.
- Preserve the user's notes and position in `build/UIReview`. Automated checks use the separate `build/manual-review/check-report` directory.

Non-UI unit tests and command-line checks may remain separate. Content-only PNG exports do not validate native window behavior. See [docs/testing.md](docs/testing.md) for commands and coverage.

# Versioning and releases

- Every PR, including documentation-only changes, must manually increase `version` in `.github/release.json` above the current `main` version. Use the version selected by the user; ask for it when preparing a new PR if none was supplied. Do not infer a version from the PR title or change type.
- Additional commits in the same PR keep its selected version while it remains greater than `main`. If another PR catches up with it, update from `main` and obtain a higher version from the user.
- All app, widget, Xcode and review builds must use that exact repository version through `Scripts/build_version.py`. The separate internal build number comes from first-parent Git history. Do not add fallback versions or conflicting build-setting overrides.
- Merging into `main` runs checks only. Publish only when the user requests a release, through **Actions → Release → Run workflow** on `main`; do not create release tags manually.

See [docs/releases.md](docs/releases.md) for the full policy and retry behavior.
