# Development

## Build and repository layout

The app and WidgetKit extension target macOS 26. Release artifacts are Apple Silicon builds; Intel is not tested. `Package.swift` builds only the shared core and its tests, with a macOS 14 minimum for that harness.

| Location | Purpose |
| --- | --- |
| `LLMUsage/App` | App entry, menu bar, refresh scheduling and `UsageStore` |
| `LLMUsage/Dashboard`, `Sessions`, `Models`, `Settings` | Product screens |
| `LLMUsage/Data`, `Services`, `Shared` | Transcript parsing, CLI/pricing services, models, storage and localization |
| `LLMUsage/Widget`, `Resources` | Widget extension, assets, plists and entitlements |
| `LLMUsage/Tests` | Shared scenarios, XCTest wrappers and synthetic fixtures |
| `Scripts` | Builds, installation, checks and private review controls |
| `Configuration` | Shared settings and ignored personal signing overrides |

Run shell scripts with Bash. `Scripts/toolchain.sh` selects `DEVELOPER_DIR`, then the toolchain in `build/AppleTools26`, then the system toolchain. If necessary, `python3 Scripts/prepare-local-toolchain.py` downloads Apple's tools into `build/` without replacing system tools; its package requires macOS 26.2+. Preserve that directory when cleaning build outputs.

`bash Scripts/build-local.sh` compiles the app and extension, regenerates icons, checks that review code is absent, signs the bundle and validates it. `--demo` opens synthetic sample data: quit any running copy, then `open 'build/LLM Usage.app' --args --demo`.

For Xcode, open `LLMUsage.xcodeproj`, select **LLMUsage → My Mac**, and configure signing for both targets. Put personal values in ignored `Configuration/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
LLM_USAGE_APP_GROUP = group.com.yourname.LLMUsage
```

Use bundle identifiers and a shared App Group registered to your team. Xcode builds use that group. The default ad-hoc script build instead gives the widget read-only access to derived snapshot files. `LLM_CODESIGN_IDENTITY` selects a signing identity for script builds; this alone does not notarize an app.

`Scripts/generate_project.py` owns the Xcode project and shared scheme. Edit the generator for structural changes and rerun it after adding/removing Swift files. `Scripts/app-sources.sh` supplies the common product sources to script builds, review builds and UI typechecking. The icon source is `LLMUsage/Shared/BrandGeometry.swift`.

Keep build products, reports, downloaded tools and previews under ignored `build/`. Do not commit local logs, exported conversations, credentials or `Configuration/Local.xcconfig`. Existing `ClaudeUsage` bundle IDs, storage keys and URL aliases preserve compatibility with older installations.

## Data flow

`UsageStore` coordinates refreshes, date/source selection, cached snapshots and model exclusions. `CCUsageService` runs the external CLI through `ProcessRunner`; the app aggregates its report, and WidgetKit reads saved snapshots. The widget does not scan logs or launch the CLI. Closing the dashboard leaves the menu bar process running; its context menu contains Quit.

The tested CLI is `ccusage@20.0.26`:

- **Claude only** runs the focused `ccusage claude session --json` report for the requested day.
- **All agents** runs the unified `ccusage session --json --all` report and the focused Claude report concurrently, then replaces the unified Claude rows. This corrects the tested CLI's Claude day-boundary errors. Both commands must succeed before saving the result.
- Switching modes invalidates incompatible caches. Historical days expire after six hours; the in-memory report cache is bounded. Failed refreshes preserve the last successful data and identify its actual date.

The app searches for the CLI, including `~/.local/bin`; Settings can select an explicit executable. Node.js is needed for the npm installation. Replacing or embedding ccusage is not implemented.

## Pricing and accounting

Usage and transcripts are processed locally. Pricing refreshes use the public LiteLLM catalog; ccusage can also retrieve prices. Costs are estimates, not invoices.

The last valid Claude, GPT/o-series and Gemini rates persist in `~/Library/Application Support/LLMUsage/Pricing/chat-pricing-v1.json`; older `claude-pricing-v1.json` files remain readable. Invalid/network responses preserve usable rates. A first successful download is needed for models absent from the CLI's embedded catalog.

Rates reach ccusage through private temporary `pricingOverrides` configuration. Explicit user overrides retain priority, and user configuration is not edited. The CLI handles cache categories, long context and Fast mode. Immutable receipts under `Pricing/Reports` record effective rates and the Codex fallback speed used for each report. A report without a receipt cannot claim tariff parity until refreshed.

Model exclusions match exact names without case sensitivity; Z.ai / GLM are excluded by default. Exclusions affect Statistics, history, menu bar and widgets while preserving session records. Models shows original amounts for reference, marks excluded rows and keeps its included-spending total separate. A mixed session without a complete per-model breakdown is excluded as a whole if any of its models is excluded.

Provider logos follow known model names independently of the coding agent. Mixed sessions show their known providers; an unknown model falls back to its source logo with a source tooltip. The daily budget uses the day's included total across sources, even when the screen is filtered to one source.

## Chat inspection

Transcript readers support local JSON, JSONL/NDJSON and supported SQLite formats. Request-level usage is available for Claude Code, Codex and Gemini; other supported formats can still be browsed. Parsing and search run away from the UI thread, with cancellation and stale-result rejection.

A recorded model request is charged once even when it contains several text/tool events. Linked events point to that request. User-message totals group related requests, including context and tools; they are not a separate prompt charge. Tool analytics shows related-request cost: rows can overlap and must not be summed. Filters do not change billing totals.

Daily reconciliation compares token categories and unrounded cost with the session report. Entire-session totals come from available logs and do not claim daily reconciliation. Unknown tariffs, damaged/undated logs and unverified fork history remain explicit. Verified Codex replay prefixes are deduplicated; Claude subagent logs are labeled.

For local offline pricing, only model names, timestamps, counters and billing metadata are passed to ccusage, never message text or tool arguments/results. Temporary files are private and removed on completion, failure or cancellation. The installed CLI catalog still affects fallback estimates.

Timing comes from recorded intervals. Request duration and TTFT remain request-level values; inferred prompt/tool intervals are marked approximate. End-to-end token throughput includes tools and waits, and is not pure generation speed. Missing timing is not reconstructed from gaps between adjacent messages. Timing is calculated before date/search filtering and included in text exports.

Long messages have bounded inline previews; the full text opens in a native text reader to avoid expensive SwiftUI layout. Token bars open detailed breakdowns, and request/tool links navigate to the timeline event.

## Private UI review

`MANUAL_REVIEW` is defined only by `Scripts/manual-review.sh`. The build uses the production `LLMUsageApp`, `AppRootView`, windows, toolbar and chat sheet. `Scripts/ManualReview` adds a catalogue, fixtures and injected external services; it does not copy product screens or provide a second app entry point.

The separate development bundle ID protects installed preferences. Synthetic services and in-memory storage replace external I/O while the normal `UsageStore` refresh/cache/error paths remain active. Login-item changes are simulated. The build requires an explicit `--manual-review` argument; shipping builds contain neither that entry point nor the catalogue. `verify-review-boundary.py` checks the shipping executable during each build.

The launcher stages a fresh signed bundle, retires only known review copies under this workspace and verifies the launched PID, executable and source fingerprint. The catalogue displays that fingerprint. See [Testing](testing.md) for operation and report recovery.
