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

## Application version

Manually choose the version for each PR in `.github/release.json`, for example `{"version": "1.5.1"}`. It must be strictly higher than the current `main` version; PR titles and commit counts do not select the visible version. Further commits in the same PR can keep that number while it remains higher than `main`.

Script builds, Xcode, the widget and the review catalogue all read this same file through `Scripts/build_version.py`, including uncommitted version edits in development builds. Development/review builds retain the **Test build** label. The separate internal build number is the first-parent Git history length. Full Git history is required; release tags are not the version source. Do not set a different `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` in `Local.xcconfig` or the environment: conflicting overrides fail the build.

Merging PRs only runs checks, so several versioned PRs can accumulate before publication. When ready, use **GitHub → Actions → Release → Run workflow** on **main**. The release uses the version of the commit selected at dispatch. See [Releases](releases.md) for validation, artifacts and retries.

## Data flow

`UsageStore` coordinates refreshes, date/source selection, cached snapshots and model exclusions. `CCUsageService` runs the external CLI through `ProcessRunner`; the app aggregates its report, and WidgetKit reads saved snapshots. The widget does not scan logs or launch the CLI. Closing the dashboard hides the existing scene and keeps its toolbar ready for the next presentation; the menu bar process stays running and its context menu contains Quit. `DashboardWindowCoordinator` observes that same scene window, forwards its native delegate behavior, and prepares the window width before SwiftUI opens an inspector. The first toolbar layout releases the initial presentation so the titlebar-only frame is never shown.

The bundled CLI is `ccusage@20.0.26-llmusage.3`, built from upstream 20.0.26 with the reviewed response-boundary patch in `Configuration/Patches`:

- **Claude only** runs the focused `ccusage claude session --json` report for the requested day.
- **All agents** runs the unified `ccusage session --json --all` report and the focused Claude report concurrently, then replaces the unified Claude rows. This corrects the tested CLI's Claude day-boundary errors. Both commands must succeed before saving the result.
- Switching modes invalidates incompatible caches. Historical days expire after six hours; the in-memory report cache is bounded. Failed refreshes preserve the last successful data and identify its actual date.

The app uses only `Contents/Helpers/ccusage`, a native arm64 executable pinned in `Configuration/Dependencies.json`. It requires no Node.js or npm. `CCUsageRuntime` gates execution on explicit consent, validates the final signed binary digest and exact version, and shares a lease across reports and transcript pricing. Existing custom-path preferences are preserved but ignored by the managed runtime; the legacy resolver remains only for injected test services.

Build scripts and the generated Xcode project use the same checksum-verified dependency cache. `Configuration/Dependencies.json` pins the upstream commit/archive, patch, Rust 1.97.1 components, and upstream LiteLLM snapshot by SHA-256. Cargo uses the upstream lockfile with `--locked`. Build tools stay under `build/Dependencies`; end users still need no compiler or package manager. This portable build recipe uses pinned Cargo directly, without requiring upstream's Nix developer shell.

To update the patch, review the diff, update its digest and helper version in the lock, and run the synthetic CLI and pricing checks. Increment `contractVersion` when accounting semantics change (this patch uses contract 2). A build receipt binds the compiled helper's digest to the locked inputs; embedding verifies that receipt and records the final signed digest and source/patch provenance in the app. The SDK/linker remain supplied by the selected Apple toolchain, so source reproducibility does not claim identical Mach-O bytes across different SDKs. Dependency versions never float at launch.

The Claude patch coalesces consecutive requestless assistant fragments only when `parentUuid` links to the previous assistant `uuid`, their session/message/model and input/cache counters agree, output does not decrease, and speed/sidechain status match. `stop_reason` is deliberately ignored: real Claude transcripts repeat `tool_use` and `end_turn` on fragments of one response. Interleaved tool blocks can also share one charge when the UUID chain passes only through results owned by the preceding tool fragment and optional `hook_success` attachments. This narrower path requires identical counters, tool-only assistant content, and disjoint tool IDs. User prompts, mixed user input, foreign tool results, unknown attachments, new text answers, changed counters or broken ancestry establish a new response. Without a trustworthy request ID, this is a structural inference: a proxy that also repeats every usage counter on distinct tool responses can make those responses indistinguishable from fragments. It is not a global message-ID deduplication rule. Unlinked gateway exports retain upstream timestamp-based counting. Both CLI loaders and chat inspection follow this rule. Deduplication precedes day filtering; a completed fragment crossing midnight belongs to the day of its most complete record. Raw logs are never rewritten.

## Pricing and accounting

Usage and transcripts are processed locally. Pricing refreshes use the public LiteLLM catalog; ccusage can also retrieve prices. Costs are estimates, not invoices.

The last valid Claude, GPT/o-series and Gemini rates persist in `~/Library/Application Support/LLMUsage/Pricing/chat-pricing-v1.json`; older `claude-pricing-v1.json` files remain readable. Invalid/network responses preserve usable rates. A first successful download is needed for models absent from the CLI's embedded catalog.

Rates reach ccusage through private temporary `pricingOverrides` configuration. Explicit user overrides retain priority, and user configuration is not edited. The CLI handles cache categories, long context and Fast mode. Immutable receipts under `Pricing/Reports` record effective rates and the Codex fallback speed used for each report. Receipts include the engine version/adapter contract. A report without a matching receipt cannot claim tariff parity until refreshed. Legacy snapshots remain displayable during migration but are not reused as fresh calculations.

Model exclusions match exact names without case sensitivity; Z.ai / GLM are excluded by default. Exclusions affect Statistics, history, menu bar and widgets while preserving session records. Models shows original amounts for reference, marks excluded rows and keeps its included-spending total separate. A mixed session without a complete per-model breakdown is excluded as a whole if any of its models is excluded.

Provider logos follow model families independently of the coding agent: Anthropic, OpenAI, Google, Z.AI (GLM/ChatGLM), DeepSeek, Qwen, Moonshot AI (Kimi), MiniMax, Mistral AI and Meta (Llama). After trimming whitespace and ignoring case, a model ID starting with `tgpt` takes priority and displays the T-Bank shield, including `tgpt/gpt-…`. Router namespaces and versioned model names are supported; opaque aliases remain unknown. Mixed sessions show deduplicated logos in a stable, overlapping stack with cutout separators and the same translucent backgrounds as solo icons, including a neutral icon for unknown models. The tooltip and accessibility label list every provider. Empty metadata uses the neutral icon only when no model names are available. Tool names remain separate source labels. Logo recognition is independent of model exclusions and pricing. Logo sources and adaptations are recorded in `LLMUsage/Resources/Providers/NOTICE.txt`.

The daily budget uses the day's included total across sources, even when the screen is filtered to one source.

## Chat inspection

Transcript readers support local JSON, JSONL/NDJSON and supported SQLite formats. Request-level usage is available for Claude Code, Codex and Gemini; other supported formats can still be browsed. Parsing and search run away from the UI thread, with cancellation and stale-result rejection.

A recorded model request is charged once even when it contains several text/tool events. Linked events point to that request. User-message totals group related requests, including context and tools; they are not a separate prompt charge. Tool analytics shows related-request cost: rows can overlap and must not be summed. Filters do not change billing totals.

Daily reconciliation compares token categories and unrounded cost with the session report. Entire-session totals come from available logs and do not claim daily reconciliation. Unknown tariffs, damaged/undated logs and unverified fork history remain explicit. Verified Codex replay prefixes are deduplicated; Claude subagent logs are labeled.

For local offline pricing, only model names, timestamps, counters and billing metadata are passed to ccusage, never message text or tool arguments/results. Temporary files are private and removed on completion, failure or cancellation. The bundled CLI catalog still affects fallback estimates.

Timing comes from recorded intervals. Request duration and TTFT remain request-level values; inferred prompt/tool intervals are marked approximate. End-to-end token throughput includes tools and waits, and is not pure generation speed. Missing timing is not reconstructed from gaps between adjacent messages. Timing is calculated before date/search filtering and included in text exports.

Long messages have bounded inline previews; the full text opens in a native text reader to avoid expensive SwiftUI layout. Token bars open detailed breakdowns, and request/tool links navigate to the timeline event.

## Private UI review

`MANUAL_REVIEW` is defined only by `Scripts/manual-review.sh`. The build uses the production `LLMUsageApp`, `AppRootView`, windows, toolbar and chat sheet. `Scripts/ManualReview` adds a catalogue, fixtures and injected external services; it does not copy product screens or provide a second app entry point.

Use this single review build for diagnostic experiments as well as regression checks. Add temporary instrumentation to this mode and inspect its actual windows; do not create throwaway geometry/chrome apps or alternate product hosts, even under ignored `build/` or `/tmp`. The repository's [agent instructions](../AGENTS.md) enforce the same workflow.

The separate development bundle ID protects installed preferences. Synthetic services and in-memory storage replace external I/O while the normal `UsageStore` refresh/cache/error paths remain active. Login-item changes are simulated. The build requires an explicit `--manual-review` argument; shipping builds contain neither that entry point nor the catalogue. `verify-review-boundary.py` checks the shipping executable during each build.

The launcher stages a fresh signed bundle, retires only known review copies under this workspace and verifies the launched PID, executable and source fingerprint. The catalogue displays that fingerprint. See [Testing](testing.md) for operation and report recovery.

Automated window checks use this same bundle: `check.sh` → `check-windows.sh` → `manual-review.sh --self-check`. Assertions live in `Scripts/ManualReview` and inspect the connected production window and its actual chat sheets. The launcher also retires the obsolete standalone window-check executables; saved notes in `build/UIReview` are preserved. Content-only PNG exports are separate and cannot verify native window chrome.

## App updates

`AppUpdateCoordinator` owns consent, persisted update preferences and the user-visible state. Development and review builds do not query the production feed. Release builds check a signed Sparkle appcast hosted as a GitHub Release asset. Both feed and ZIP require the pinned Ed25519 key. Release notes are plain text.

Sparkle automatic downloads are deliberately disabled: its installer can install downloaded updates when the app quits. `UpdateDownloadCache` downloads and verifies an archive without starting the installer. On an install click or the visible automatic countdown, the store pauses refresh/backfill and waits for active work, the shared runtime blocks new calculations, and a short-lived loopback server hands the verified archive to Sparkle. Sparkle independently verifies it again before extraction and replacement. Failures resume the current app; successful updates relaunch it. No usage data is stored inside the replaceable app bundle.

Settings can postpone installation or revoke component consent. Update archives are limited to 256 MiB, redirects require HTTPS, and at most two complete archives are retained. Test-only loopback download permissions compile only under `UPDATE_TESTING`; normal builds accept GitHub release ZIPs over HTTPS.
