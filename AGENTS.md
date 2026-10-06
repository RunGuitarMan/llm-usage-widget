# UI testing and debugging

Build one application with `bash Scripts/build-local.sh`: `build/LLM Usage.app`.
Normal use, interactive review, automated window checks and release validation must launch that exact built artifact, including its embedded WidgetKit extension.

- `bash Scripts/manual-review.sh` only launches the existing app with `--review`; it must never compile, copy, repackage, change bundle IDs, or re-sign a test variant. Command-1 opens its catalogue.
- `bash Scripts/check-windows.sh` checks normal startup with demo data, then runs the catalogue self-check using that same executable. Build first; stale or modified artifacts must fail instead of silently rebuilding.
- Review is a runtime mode in the common executable. It injects synthetic external services and isolated preferences/storage, but uses the same `LLMUsageApp`, `AppRootView`, scenes, window opening, toolbar, sheets and geometry. Do not add `MANUAL_REVIEW` compilation branches.
- Keep scenario controls and diagnostics in `Scripts/ManualReview`, dormant unless review is explicitly requested. Inspect actual app windows and controls; never create separate diagnostic apps, alternate entry points, or manually hosted copies of product windows, even under `build/` or `/tmp`.
- Verify executable SHA-256, source identity and all signed bundle contents before and after checks with `Scripts/app_artifact.py`. Publish the tested artifact without recompiling it.
- Preserve the user's notes and position in `build/UIReview`. Automated checks use `build/manual-review/check-report`; disposable interactive review uses `LLM_REVIEW_REPORT_DIR`.

Non-UI unit tests and command-line checks may remain separate. Content-only PNG exports do not validate native window behavior. See [docs/testing.md](docs/testing.md) for commands and coverage.

# Versioning and releases

- Every PR, including documentation-only changes, must manually increase `version` in `.github/release.json` above the current `main` version. Use the version selected by the user; ask for it when preparing a new PR if none was supplied. Do not infer a version from the PR title or change type.
- Additional commits in the same PR keep its selected version while it remains greater than `main`. If another PR catches up with it, update from `main` and obtain a higher version from the user.
- All app, widget, Xcode and review builds must use that exact repository version through `Scripts/build_version.py`. The separate internal build number comes from first-parent Git history. Do not add fallback versions or conflicting build-setting overrides.
- Merging into `main` runs checks only. Publish only when the user requests a release, through **Actions → Release → Run workflow** on `main`; do not create release tags manually.

See [docs/releases.md](docs/releases.md) for the full policy and retry behavior.
