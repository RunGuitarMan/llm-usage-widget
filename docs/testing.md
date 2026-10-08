# Testing

## Commands

Run from the repository root with macOS SDK 26+ selected (see [Development](development.md)). Build once with `bash Scripts/build-local.sh` before `check.sh`, `check-windows.sh` or interactive review. Launchers refuse missing/stale artifacts and never rebuild them.

| Command | Coverage |
| --- | --- |
| `bash Scripts/check.sh` | Shared core scenarios, SwiftPM module boundary, native menu checks, app/widget typechecking and production-scene window checks |
| `bash Scripts/check-icons.sh` | Icon geometry, assets and appearance |
| `bash Scripts/check-updates.sh` | Real signed Sparkle replacement/relaunch of disposable apps; manual, download-only quit, invalid signature and automatic modes |
| `python3 -m unittest discover -s Scripts -p 'test_*.py' -v` | Installer rollback/concurrency, manual version increases, stale/tampered release artifacts and safe release publication |
| `swift test` | Core XCTest suite; requires full Xcode |
| `bash Scripts/check-ui.sh` | App and widget typechecking only |
| `bash Scripts/check-windows.sh` | Normal startup smoke check and review self-check against the same executable |
| `bash Scripts/build-local.sh` | One complete app/widget build, signatures, bundle structure and immutable artifact manifest |
| `bash Scripts/manual-review.sh --self-check` | Production window geometry, first-show and reopen chrome, sidebar corners after automatic inspector expansion, trailing toolbar, sidebar/focus, scrolling, session navigation, real chat sheets, catalogue scenarios, loading/error recovery and report persistence |
| `bash Scripts/manual-review.sh --widget-check` | Focused real-file app → provider publication, gallery without storage, stale/midnight transitions, corruption recovery, cached launch-job recovery and replacement of a running signed process; same common app |
| `bash Scripts/manual-review.sh --focus-check` | Focused sidebar pixels and live SwiftUI/native focus in both themes; active cases precede final app deactivation |
| `bash Scripts/manual-review.sh --telemetry-check` | Focused production telemetry settings/status/consent/export/chat in RU/EN, light/dark and compact windows; waits for the export snapshot to populate |
| `python3 Scripts/widget_host_check.py --since <ISO-8601>` | Actual system WidgetKit deliveries for all 9 kind/size pairs; fails on missing/stale deliveries, old extension versions, storage errors, archive rejection or launchd registration/executable errors |

CI runs the first four commands and the shipping build. `check.sh` calls `check-windows.sh`, which launches the already built common application in normal and review modes. Native checks are visible on screen and require a logged-in macOS GUI session. Product windows must come from `LLMUsageApp` and its scenes: do not add a separate `@main` or hand-built `NSWindow` around a product screen for regression checks. Windowless component measurements remain in the same process. These checks do not substitute for a manual system-widget check.

**CI** runs on PRs and pushes to `main`, and can also be started manually. It never publishes a release. **Release** is a separate manually dispatched workflow on `main`; it reuses the full CI checks for its selected commit before publishing. See [Releases](releases.md) for the launch sequence.

The required **Tests** check rejects PRs whose `.github/release.json` version is unchanged or lower than their `main` base, including documentation-only PRs. To check the comparison locally, fetch the latest base with `git fetch origin main`, then run `python3 Scripts/release_version.py --check-increase origin/main`. Python tests cover numeric version ordering, parallel PR collisions, unchanged/lower versions, shared app/widget metadata, publication retries and rejection of older releases.

`LLMUsage/Tests/*Scenarios.swift` contains the shared assertions used by both the portable harness and XCTest wrappers. Add checks there instead of duplicating them. Existing coverage includes date/timezone boundaries, model attribution and exclusions, stream/replay deduplication, pricing persistence, transcript timing, search cancellation, stale responses, cache validation, clock changes and CLI process cleanup.

Claude telemetry adds 21 shared scenario groups covering add-only settings transactions, races/faults, privacy canaries, numeric/framing/gzip bounds, loopback HTTP, restart/dedup/recovery, retention/quota, reconciliation and anonymous ZIP exports. After compilation, `build/portable-checks --telemetry-only` runs that focused subset without launching a UI. Tests use private temporary configurations/stores and never edit the user's Claude settings.

For accounting changes, `bash Scripts/check-claude-accounting.sh --cli /absolute/path/to/ccusage` compiles once and runs only the accounting/telemetry scenarios, including the real helper. It does not launch an app or inspect personal Claude logs. The numeric 1.6.1 regression covers 114 incomplete requests, 84 missing requests and a service call: the known total increases from $14.0709776 to $28.8634092. Identities, timestamps and transcript text in the fixture are synthetic. The checks compare both report modes with chat detail, custom tariffs, exclusions, repeated events, conflicting IDs, unknown counters, snapshot overlap, cache TTL and midnight attribution. CI also includes these scenarios in XCTest and the bundled-helper checks.

The catalogue adds onboarding, preview/conflict, ready/receiving/waiting/error/off, export and chat telemetry scenarios. Native checks inspect the production controls and sheets in RU/EN, light/dark and compact sizes. Review uses isolated synthetic settings and a free loopback port; automatic checks preserve `build/UIReview`.

Run `python3 Scripts/check-claude-streams.py` after building the app to check both real CLI loaders against the shared response-boundary fixtures (streams, reused gateway IDs, replays and midnight). `build/portable-checks --bundled-cli` additionally compares the application reports in both source modes with priced chat detail on those same fixtures.

After building the app, run `build/portable-checks --bundled-cli` to verify the shipped native helper against synthetic logs and pricing fixtures. For optional system-CLI integration checks, use `bash Scripts/check.sh --live-cli` for saved/offline pricing or `bash Scripts/check.sh --chat-cli` for transcript calculations. Both use synthetic logs; the live pricing check also needs network access to the price catalog and the tested ccusage version. They do not validate every upstream CLI version.

To test the Xcode app target with signing configured:

```sh
xcodebuild -project LLMUsage.xcodeproj -scheme LLMUsage \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test
```

## Manual review and saved notes

CI also builds the Xcode app and embedded widget without launching them and checks their version metadata against the same repository version and Git build number as script builds.

Run `bash Scripts/build-local.sh` once, then `bash Scripts/manual-review.sh` to launch that same app in review mode. The catalogue offers 99 curated scenarios, RU/EN, light/dark appearance and width presets. It is a checklist, not exhaustive coverage of every UI combination. **⌘1** reopens the catalogue. Use Next/Back to navigate and record Passed, Problem or Skip with notes. Loading scenarios can be released with **Успешный ответ источника**.

Files under `build/UIReview/`:

- `review-progress.json`: marks and notes, saved atomically per scenario/language/theme/size.
- `review-position.json`: the current scenario, language, theme and size, restored on restart.
- `launch.json`: the current launch receipt, PID, actual executable SHA-256 and runtime mode.

**Отчёт** opens this folder. Preserve it when cleaning builds; copy it before experimenting with report files. Relaunching keeps saved notes and resumes the position. If the app hangs, preserve the report and collect a process sample before stopping the identified development process; restarting the review build reads the existing files.

The launcher does not replace or mutate the app. It may stop a previous launcher-owned review session; an ordinary running session must be closed explicitly. `build-local.sh` builds without launching; the old review `--build-only` option is removed. `--self-check` uses `build/manual-review/check-report`; `--normal-smoke` uses `build/manual-review/normal-report`. Each records `artifact.json` and the executable hash. The self-check covers scenario switching and invariants, not every clickable control.

`--app /absolute/path/LLM\ Usage.app --manifest /absolute/path/app-artifact.json` selects another already built artifact explicitly; the same source/hash/signature checks still apply. Legacy `build/manual-review/LLM Usage.app` copies are no longer a test target.

For disposable interactive checks without changing saved notes or position, use `LLM_REVIEW_REPORT_DIR="$PWD/build/manual-review/interactive-report" bash Scripts/manual-review.sh`. This override applies only to interactive review; automated checks always use `build/manual-review/check-report`.

## Visual and system checks

`LLM_REVIEW_CHECKS=widget bash Scripts/check-windows.sh` runs a focused check in the same production review app: real URL Apple events reopen its hidden/minimized dashboard, preserve dated problem destinations, and ignore invalid routes. It also runs the shared data-status scenarios, including startup URL buffering and atomic replacement of an incomplete cost. It does not launch the installed app or validate the system WidgetKit host. The full self-check includes these assertions too.

`bash Scripts/render-previews.sh` writes previews to `build/Previews`. Useful filters include `--widgets`, `--menus`, `--sidebars`, `--models`, `--ui-polish` and `--language=ru`/`en`. These render content; native titlebar glass, popover positioning and window focus require a live app.

The shared data-status checks cover pure staleness without a CLI failure, simultaneous failures and incomplete costs, persisted app/widget parity, historical error dates, retry recovery and problem deep links. `overview-stale`, `overview-multiple`, `overview-storage`, the matching menu scenarios and all three widget variants exercise the same production diagnostics. Widget gallery links are handled inside the review app; they never launch an installed copy. Native self-checks click the actual warning controls and the production details sheet in RU/EN and both appearances. Gallery checks do not validate WidgetKit's system refresh scheduling.

Before a UI release, verify:

- Statistics: expand/collapse sessions with one main scroll area; sort/search/filter and follow a session link.
- Toolbar: switch sections and dates repeatedly; hide/show the sidebar with an active warning. Buttons must not duplicate or inherit the warning fill.
- Calendar and budget: select a date in both locales; step through days with the date capsule, including rapid clicks, month boundaries and today's disabled forward arrow. Verify that a day arrow dismisses the open calendar and that the capsule stays in place. Change a budget in Settings and check its meter, including with a source filter.
- Provider logos: use `provider-sessions`, `provider-models` and `provider-inspector` for GLM in Claude Code, the T-Bank shield for `tgpt…`, all bundled brands, unknown/empty models and mixed sessions. Self-checks validate bundled marks and production logo bindings and labels in RU/EN and both themes. Review-only native probes observe the real logo groups; no product window is recreated.
- Chat: token details, tool/request links, search, full-text reading and long messages at narrow width in both themes.
- Claude service events: `chat-service-events` and `chat-service-errors` cover compaction metrics, API retries, hook failures, expandable hook instructions and editor diagnostics. Self-checks click the production disclosures, full-text and JSON readers in RU/EN and both themes at compact width. Shared core scenarios cover incomplete records, search, day/error/tool filters, lossless exports and unchanged turn-duration attribution.
- Sidebar: active/inactive windows, dark/light appearance, increased contrast and reduced transparency.

Install the app to check WidgetKit placement, gallery registration, refreshes and dated links. The review catalogue shows actual widget content but does not reproduce the system WidgetKit host. Cross-machine installation and interrupted system-level installation are also separate manual checks.

### Widget refresh regression

The 1.5.3 incident was downstream of a successful snapshot read: a process mapped from an old build stayed alive after bundle replacement, and `chronod` rejected its archives with `bundleStubNotSupported` / `Bundle version did not match`. File publication or content screenshots alone therefore cannot establish that a desktop widget updated.

The required self-check includes the production `UsageTimelineProvider`, reading files published by the real `UsageStore` and `SnapshotRepository`. It checks A → B, generation timestamps, a clean install, preview data without disk access, corruption/recovery and midnight/staleness. A non-UI signed process fixture then replaces the executable inode while the original process remains alive; the production lifecycle code must retain the current process and retire the stale one. This fixture uses copies of system CLI utilities, not another application or window. Python regressions also feed the captured archive-rejection signature to the system-host gate: fresh provider receipts cannot turn that failure into a pass.

The follow-up disappearance had a different trigger: launchd retained the deleted build's executable path inside `chronod`'s private domain. Focused tests exercise the production parser and recovery decision with captured field structure, a missing old build, healthy/foreign jobs, truncated or ambiguous diagnostics, PID reuse, changing jobs and the restart cooldown. Observations and signalling are injected, so automated checks never restart the user's real widget host. The system-host gate also rejects the captured `Missing executable detected` and conflicting re-bootstrap errors, even when provider delivery receipts exist.

For system acceptance, use the **same built artifact** on a logged-in macOS test account, first on a clean installation and then after replacing an older build without logging out:

1. Record the test start time with timezone. Open the system gallery; inspect the current icon and readable previews for all three kinds and sizes.
2. Place all nine combinations. In normal mode publish data A, then refresh after a known source change B. Compare amounts and dates with the app, including while Finder is active and after closing/reopening the dashboard. Runtime review's in-memory cards do not count as this check.
3. Run `python3 Scripts/widget_host_check.py --since 2026-10-06T17:00:00Z` with the actual start time, against that artifact. It compares logged extension deliveries with the latest persisted generation and checks system rejection errors. No configured widgets or a missing family is a failure. Keep its JSON receipt with the artifact hash and visual review evidence.
4. Repeat after an update with the previous extension still running. Check dated session links and gallery icon as well as refreshed values.
5. On the test account, also install from a temporary location, move the same app to its final location and remove the temporary copy. Launch the final app; a retained old launch job must recover automatically, and widgets must remain in both the gallery and desktop. Preserve evidence of the old/new job paths and lifecycle recovery log. Do not reset system databases or delete widget placements to obtain a pass.

The desktop check requires real configured widgets; hosted CI does not provision desktop placements through a supported WidgetKit API. CI covers the deterministic process-replacement regression and provider/storage contracts. A green CI or a successful log gate does not replace inspection of actual system rendering, and cannot promise detection of every future macOS defect.

Update integration checks require a logged-in macOS GUI session. They use fresh test keys, isolated bundle IDs and synthetic services; they never install over LLM Usage or read agent logs. Portable runtime scenarios cover consent, exact-version and digest rejection, active-work quiescence, the verified loopback handoff and engine provenance. `verify-bundle.py` checks the final signed helper and Sparkle configuration.
