# Testing

## Commands

Run from the repository root with macOS SDK 26+ selected (see [Development](development.md)).

| Command | Coverage |
| --- | --- |
| `bash Scripts/check.sh` | Shared core scenarios, SwiftPM module boundary, native menu checks, app/widget typechecking and isolated window checks |
| `bash Scripts/check-icons.sh` | Icon geometry, assets and appearance |
| `bash Scripts/check-updates.sh` | Real signed Sparkle replacement/relaunch of disposable apps; manual, download-only quit, invalid signature and automatic modes |
| `python3 -m unittest discover -s Scripts -p 'test_*.py' -v` | Installer rollback/concurrency, release versions and safe release publication |
| `swift test` | Core XCTest suite; requires full Xcode |
| `bash Scripts/check-ui.sh` | App and widget typechecking only |
| `bash Scripts/check-windows.sh` | Native toolbar, sidebar, geometry, scrolling, inspector and session navigation with synthetic data |
| `bash Scripts/build-local.sh` | Complete app/widget build, signatures, bundle structure and absence of private review code |
| `bash Scripts/manual-review.sh --self-check` | Real app scenes, catalogue scenarios, repeated toolbar/chat transitions, loading/error recovery and report persistence |

CI runs the first four commands, the shipping build and a compile-only review build (`manual-review.sh --build-only`). Native window checks are visible on screen. They use isolated hosts for components; the review self-check uses the production app entry point. Neither substitutes for a manual system-widget check.

`LLMUsage/Tests/*Scenarios.swift` contains the shared assertions used by both the portable harness and XCTest wrappers. Add checks there instead of duplicating them. Existing coverage includes date/timezone boundaries, model attribution and exclusions, stream/replay deduplication, pricing persistence, transcript timing, search cancellation, stale responses, cache validation, clock changes and CLI process cleanup.

For optional CLI integration checks, use `bash Scripts/check.sh --live-cli` for saved/offline pricing or `bash Scripts/check.sh --chat-cli` for transcript calculations. Both use synthetic logs; the live pricing check also needs network access to the price catalog and the tested ccusage version. They do not validate every upstream CLI version.

To test the Xcode app target with signing configured:

```sh
xcodebuild -project LLMUsage.xcodeproj -scheme LLMUsage \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test
```

## Manual review and saved notes

Run `bash Scripts/manual-review.sh`. The catalogue offers 84 curated scenarios, RU/EN, light/dark appearance and width presets. It is a checklist, not exhaustive coverage of every UI combination. **⌘1** reopens the catalogue. Use Next/Back to navigate and record Passed, Problem or Skip with notes. Loading scenarios can be released with **Успешный ответ источника**.

Files under `build/UIReview/`:

- `review-progress.json`: marks and notes, saved atomically per scenario/language/theme/size.
- `review-position.json`: the current scenario, language, theme and size, restored on restart.
- `launch.json`: the current launch receipt and source fingerprint.

**Отчёт** opens this folder. Preserve it when cleaning builds; copy it before experimenting with report files. Relaunching keeps saved notes and resumes the position. If the app hangs, preserve the report and collect a process sample before stopping the identified development process; restarting the review build reads the existing files.

All launcher modes replace the previous review bundle and stop its process, so finish an active manual session before rebuilding. `--build-only` builds without launching. `--self-check` uses a separate `build/manual-review/check-report` folder. It tests scenario switching and invariants, not every clickable control.

## Visual and system checks

`bash Scripts/render-previews.sh` writes previews to `build/Previews`. Useful filters include `--widgets`, `--menus`, `--sidebars`, `--models`, `--ui-polish` and `--language=ru`/`en`. These render content; native titlebar glass, popover positioning and window focus require a live app.

Before a UI release, verify:

- Statistics: expand/collapse sessions with one main scroll area; sort/search/filter and follow a session link.
- Toolbar: switch sections and dates repeatedly; hide/show the sidebar with an active warning. Buttons must not duplicate or inherit the warning fill.
- Calendar and budget: select a date in both locales; change a budget in Settings and check its meter, including with a source filter.
- Provider logos: known, unknown and mixed models in sessions, Models and the inspector.
- Chat: token details, tool/request links, search, full-text reading and long messages at narrow width in both themes.
- Sidebar: active/inactive windows, dark/light appearance, increased contrast and reduced transparency.

Install the app to check WidgetKit placement, gallery registration, refreshes and dated links. The review catalogue shows actual widget content but does not reproduce the system WidgetKit host. Cross-machine installation and interrupted system-level installation are also separate manual checks.

Update integration checks require a logged-in macOS GUI session. They use fresh test keys, isolated bundle IDs and synthetic services; they never install over LLM Usage or read agent logs. Portable runtime scenarios cover consent, exact-version and digest rejection, active-work quiescence, the verified loopback handoff and engine provenance. `verify-bundle.py` checks the final signed helper and Sparkle configuration.
