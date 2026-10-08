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

`bash Scripts/build-local.sh` compiles the app and extension, regenerates icons, includes the dormant runtime review catalogue, signs the bundle and validates it. `--demo` opens synthetic sample data: quit any running copy, then `open 'build/LLM Usage.app' --args --demo`.

For Xcode, open `LLMUsage.xcodeproj`, select **LLMUsage → My Mac**, and configure signing for both targets. Put personal values in ignored `Configuration/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
LLM_USAGE_APP_GROUP = group.com.yourname.LLMUsage
```

Use bundle identifiers and a shared App Group registered to your team. Xcode builds use that group. The default ad-hoc script build instead gives the widget read-only access to derived snapshot files. `LLM_CODESIGN_IDENTITY` selects a signing identity for script builds; this alone does not notarize an app.

`Scripts/generate_project.py` owns the Xcode project and shared scheme. Edit the generator for structural changes and rerun it after adding/removing Swift files. `Scripts/app-sources.sh` supplies the common product sources to script builds, review builds and UI typechecking. The icon source is `LLMUsage/Shared/BrandGeometry.swift`.

Keep build products, reports, downloaded tools and previews under ignored `build/`. Do not commit local logs, exported conversations, credentials or `Configuration/Local.xcconfig`. Existing `ClaudeUsage` bundle IDs, storage keys and URL aliases preserve compatibility with older installations.

Script builds use `local.ClaudeUsage.Local` for development. Published releases retain the historical `local.ClaudeUsage.Development` identity and its data/widget placements; the word “Development” in that old identifier does not describe the release channel. Development builds cannot override their identity to the release ID. This prevents local builds from competing with an installed release in LaunchServices and WidgetKit. The extension is built directly inside the staged host, with the same newly generated icon and a content-derived icon filename.

On normal startup the app registers its current bundle with LaunchServices and checks only same-user processes whose signed identifier and executable suffix identify its widget. It obtains the running code's identity with `kSecGuestAttributeDynamicCode`, so replacing/unlinking the on-disk executable cannot hide the old process or substitute the new file's identity. A previous canonical path or different code digest triggers a verified SIGTERM of that old extension, then a timeline reload. The current extension and other app identities remain untouched. No global LaunchServices reset, Notification Center restart or widget placement deletion is used. Runtime review and normal demo smoke tests do not repair the installed widget registration.

If `chronod` retained a launchd job pointing to a previous build location, retiring an extension alone cannot help: the old executable may already be deleted and no extension can start. Startup reads only this widget's job using bounded `launchctl print` calls. A confirmed path mismatch permits SIGTERM of the same user's system `chronod`, so macOS recreates its private launchd domain. The host's kernel path, PID/start timestamp and the cached job are rechecked before signalling. Healthy/current jobs, other bundle IDs, unavailable diagnostics and unknown output formats do not trigger recovery. Successful recovery is limited to once per five minutes. This exceptional repair briefly reloads the user's shared widget host; it preserves widget placements and never escalates to SIGKILL or disables system protections.

## Application version

Manually choose the version for each PR in `.github/release.json`, for example `{"version": "1.5.1"}`. It must be strictly higher than the current `main` version; PR titles and commit counts do not select the visible version. Further commits in the same PR can keep that number while it remains higher than `main`.

Script builds, Xcode, the widget and the review catalogue all read this same file through `Scripts/build_version.py`, including uncommitted version edits in development builds. Development/review builds retain the **Test build** label. The separate internal build number is the first-parent Git history length. Full Git history is required; release tags are not the version source. Do not set a different `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` in `Local.xcconfig` or the environment: conflicting overrides fail the build.

Merging PRs only runs checks, so several versioned PRs can accumulate before publication. When ready, use **GitHub → Actions → Release → Run workflow** on **main**. The release uses the version of the commit selected at dispatch. See [Releases](releases.md) for validation, artifacts and retries.

## Data flow

`UsageStore` coordinates refreshes, date/source selection, cached snapshots and model exclusions. `CCUsageService` runs the external CLI through `ProcessRunner`; the app aggregates its report, and WidgetKit reads saved snapshots. The widget does not scan logs or launch the CLI. Closing the dashboard hides the existing scene and keeps its toolbar ready for the next presentation; the menu bar process stays running and its context menu contains Quit. `DashboardWindowCoordinator` observes that same scene window, forwards its native delegate behavior, and prepares the window width before SwiftUI opens an inspector. The first toolbar layout releases the initial presentation so the titlebar-only frame is never shown.

The bundled CLI is `ccusage@20.0.26-llmusage.4`, built from upstream 20.0.26 with the reviewed response-boundary patch in `Configuration/Patches`:

- **Claude only** runs the focused `ccusage claude session --json` report for the requested day.
- **All agents** runs the unified `ccusage session --json --all` report and the focused Claude report concurrently, then replaces the unified Claude rows. This corrects the tested CLI's Claude day-boundary errors. Both commands must succeed before saving the result.
- Switching modes invalidates incompatible caches. Historical days expire after six hours; the in-memory report cache is bounded. Failed refreshes preserve the last successful data and identify its actual date.

The app uses only `Contents/Helpers/ccusage`, a native arm64 executable pinned in `Configuration/Dependencies.json`. It requires no Node.js or npm. `CCUsageRuntime` gates execution on explicit consent, validates the final signed binary digest and exact version, and shares a lease across reports and transcript pricing. Existing custom-path preferences are preserved but ignored by the managed runtime; the legacy resolver remains only for injected test services.

Build scripts and the generated Xcode project use the same checksum-verified dependency cache. `Configuration/Dependencies.json` pins the upstream commit/archive, patch, Rust 1.97.1 components, and upstream LiteLLM snapshot by SHA-256. Cargo uses the upstream lockfile with `--locked`. Build tools stay under `build/Dependencies`; end users still need no compiler or package manager. This portable build recipe uses pinned Cargo directly, without requiring upstream's Nix developer shell.

To update the patch, review the diff, update its digest and helper version in the lock, and run the synthetic CLI and pricing checks. Increment `contractVersion` when accounting semantics change (this patch uses contract 3). A build receipt binds the compiled helper's digest to the locked inputs; embedding verifies that receipt and records the final signed digest and source/patch provenance in the app. The SDK/linker remain supplied by the selected Apple toolchain, so source reproducibility does not claim identical Mach-O bytes across different SDKs. Dependency versions never float at launch.

The Claude patch coalesces consecutive requestless assistant fragments only when `parentUuid` links to the previous assistant `uuid`, their session/message/model and input/cache counters agree, output does not decrease, and speed/sidechain status match. `stop_reason` is deliberately ignored: real Claude transcripts repeat `tool_use` and `end_turn` on fragments of one response. Interleaved tool blocks can also share one charge when the UUID chain passes only through results owned by the preceding tool fragment and optional `hook_success` attachments. This narrower path requires identical counters, tool-only assistant content, and disjoint tool IDs. User prompts, mixed user input, foreign tool results, unknown attachments, new text answers, changed counters or broken ancestry establish a new response. Without a trustworthy request ID, this is a structural inference: a proxy that also repeats every usage counter on distinct tool responses can make those responses indistinguishable from fragments. It is not a global message-ID deduplication rule. Unlinked gateway exports retain upstream timestamp-based counting. Both CLI loaders and chat inspection follow this rule. Deduplication precedes day filtering; a completed fragment crossing midnight belongs to the day of its most complete record. Raw logs are never rewritten.

## Pricing and accounting

Usage and transcripts are processed locally. Pricing refreshes use the public LiteLLM catalog; ccusage can also retrieve prices. Costs are estimates, not invoices.

The last valid Claude, GPT/o-series and Gemini rates persist in `~/Library/Application Support/LLMUsage/Pricing/chat-pricing-v1.json`; older `claude-pricing-v1.json` files remain readable. Invalid/network responses preserve usable rates. A first successful download is needed for models absent from the CLI's embedded catalog.

Rates reach ccusage through private temporary `pricingOverrides` configuration. Explicit user overrides retain priority, and user configuration is not edited. The CLI handles cache categories, long context and Fast mode. Immutable receipts under `Pricing/Reports` record effective rates and the Codex fallback speed used for each report. Receipts include the engine version/adapter contract. A report without a matching receipt cannot claim tariff parity until refreshed. Legacy snapshots remain displayable during migration but are not reused as fresh calculations.

Model exclusions match exact names without case sensitivity; Z.ai / GLM are excluded by default. Exclusions affect Statistics, history, menu bar and widgets while preserving session records. Models shows original amounts for reference, marks excluded rows and keeps its included-spending total separate. A mixed session without a complete per-model breakdown is excluded as a whole if any of its models is excluded.

Provider logos follow model families independently of the coding agent: Anthropic, OpenAI, Google, Z.AI (GLM/ChatGLM), DeepSeek, Qwen, Moonshot AI (Kimi), MiniMax, Mistral AI and Meta (Llama). After trimming whitespace and ignoring case, a model ID starting with `tgpt` takes priority and displays the T-Bank shield, including `tgpt/gpt-…`. Router namespaces and versioned model names are supported; opaque aliases remain unknown. Mixed sessions show deduplicated logos in a stable, overlapping stack with cutout separators and the same translucent backgrounds as solo icons, including a neutral icon for unknown models. The tooltip and accessibility label list every provider. Empty metadata uses the neutral icon only when no model names are available. Tool names remain separate source labels. Logo recognition is independent of model exclusions and pricing. Logo sources and adaptations are recorded in `LLMUsage/Resources/Providers/NOTICE.txt`.

The daily budget uses the day's included total across sources, even when the screen is filtered to one source.

Daily diagnostics are scoped to the report being displayed. The dashboard uses the selected date; the menu and widgets use the current date. Browsing history cannot add past-date warnings to those surfaces. Incomplete cost is an informational control beside the amount, not a global dashboard banner; settings do not inherit report banners. Hidden notices are acknowledged by date and a stable cause/model fingerprint, survive retries/relaunch, and remain accessible from the amount's **Data status** context menu. New causes and new occurrences after a successful repair are visible again. The explicit diagnostics sheet can expand other dates and force recalculation of all affected days, with progress and separate full/partial/failed outcomes.

Cost diagnostics retain typed reasons, including missing rates, unreadable or ambiguous sources, source/report mismatch, telemetry ambiguity, cross-day cumulative totals and calculation failure. Accepted reports replace restored diagnostics permanently. The accounting adapter's engine revision invalidates old daily caches while retaining displayable totals during migration. Daily telemetry recovery considers events on the requested date and late completions linked to that date's requests, while conflict detection still spans all deliveries. Non-telemetry snapshot accounting streams logs up to 256 MiB, retaining only bounded accounting metadata and response-boundary identities; it does not retain message/tool bodies. Missing historical evidence remains an explicit limitation rather than an invented charge.

## Chat inspection

Transcript readers support local JSON, JSONL/NDJSON and supported SQLite formats. Request-level usage is available for Claude Code, Codex and Gemini; other supported formats can still be browsed. Parsing and search run away from the UI thread, with cancellation and stale-result rejection.

A recorded model request is charged once even when it contains several text/tool events. Linked events point to that request. User-message totals group related requests, including context and tools; they are not a separate prompt charge. Tool analytics shows related-request cost: rows can overlap and must not be summed. Filters do not change billing totals.

Daily reconciliation compares token categories and unrounded cost with the session report. Entire-session totals come from available logs and do not claim daily reconciliation. Unknown tariffs, damaged/undated logs and unverified fork history remain explicit. Verified Codex replay prefixes are deduplicated; Claude subagent logs are labeled.

For local offline pricing, only model names, timestamps, counters and billing metadata are passed to ccusage, never message text or tool arguments/results. Temporary files are private and removed on completion, failure or cancellation. The bundled CLI catalog still affects fallback estimates.

Timing comes from recorded intervals. Request duration and TTFT remain request-level values; inferred prompt/tool intervals are marked approximate. End-to-end token throughput includes tools and waits, and is not pure generation speed. Missing timing is not reconstructed from gaps between adjacent messages. Timing is calculated before date/search filtering and included in text exports.

Long messages have bounded inline previews; the full text opens in a native text reader to avoid expensive SwiftUI layout. Token bars open detailed breakdowns, and request/tool links navigate to the timeline event.

## Runtime UI review of the common app

`bash Scripts/build-local.sh` creates one signed `build/LLM Usage.app`, with the real widget extension and `Scripts/ManualReview` compiled into the same executable. `bash Scripts/manual-review.sh` only launches it with `--review`. No compilation flag, alternate bundle ID, Info.plist mutation, copying or signing occurs at review launch. Without that argument the catalogue and fixture controller are inactive.

Normal and review startup share `LLMUsageApp`, `AppRootView`, all scenes, window opening, toolbar, sheets and geometry. Review injects synthetic external services and in-memory storage into `UsageStore`, uses a private UserDefaults suite, and simulates login-item changes. Its updater is inactive. Review must never change window setup to make a test pass. Content-only PNG exports remain separate and cannot verify native window chrome.

`build/app-artifact.json` records the source fingerprint, Git commit, executable SHA-256 and every file/link in the signed app, including WidgetKit and Sparkle. The launcher rejects stale sources or changed bundle contents, verifies the launched PID/path/hash/mode from the common dashboard, and checks the artifact again after the run. It never silently rebuilds. Close the app and explicitly run the builder after source changes. Build/check locks prevent concurrent replacement. Additional checks in the same app do not require another build.

`check-windows.sh` first launches normal startup with `--demo` (no review catalogue and no user log reads), then runs the runtime catalogue self-check against that exact artifact. Release runs these checks on its final release-channel app before archiving it, without a subsequent compilation or re-signing. The normal startup smoke check does not prove live CLI or system WidgetKit behavior.

Use this same app for diagnostic experiments. The [agent instructions](../AGENTS.md) prohibit alternate product windows and diagnostic apps. Saved notes and position in `build/UIReview` remain separate from automated reports. See [Testing](testing.md) for commands and report recovery.

## App updates

`AppUpdateCoordinator` owns consent, persisted update preferences and the user-visible state. Development builds and runtime review sessions do not query the production feed. Release builds check a signed Sparkle appcast hosted as a GitHub Release asset. Both feed and ZIP require the pinned Ed25519 key. Release notes are plain text.

Sparkle automatic downloads are deliberately disabled: its installer can install downloaded updates when the app quits. `UpdateDownloadCache` downloads and verifies an archive without starting the installer. On an install click or the visible automatic countdown, the store pauses refresh/backfill and waits for active work, the shared runtime blocks new calculations, and a short-lived loopback server hands the verified archive to Sparkle. Sparkle independently verifies it again before extraction and replacement. Failures resume the current app; successful updates relaunch it. No usage data is stored inside the replaceable app bundle.

Settings can postpone installation or revoke component consent. Update archives are limited to 256 MiB, redirects require HTTPS, and at most two complete archives are retained. Test-only loopback download permissions compile only under `UPDATE_TESTING`; normal builds accept GitHub release ZIPs over HTTPS.

### Claude cost parity (1.5.5)

The helper preserves aggregate cache writes when the TTL breakdown is empty/zero, using its existing 5-minute fallback. A nonzero duration breakdown remains authoritative. Fuzzy pricing does not cross between ordinary and `:batch` keys; explicit overrides retain precedence.

`ClaudeSessionAccounting` validates top-level `modelUsage` snapshots against the same session's deduplicated visible usage. It adds only monotonically increasing uncached input/output differences when model aliases are unambiguous, cache counters match, there are no web-search charges or fast-mode ambiguity, and the aggregate difference cannot cross a pricing tier. Repeated snapshots replace prior cumulative differences; they are not new calls. `ClaudeAccountingService` reconciles both app report modes, pricing these sanitized counters in one extra isolated helper invocation using the same configuration. It never adds saved `costUSD` to independently priced messages.

Chat shows the difference as background usage without attaching it to a prompt/tool or inventing a request count. A cumulative difference spanning multiple dates remains in whole-session chat totals, but is excluded from daily buckets with incomplete accounting indicated. Missing/invalid snapshots never invent overhead. The helper engine contract invalidates incompatible cached reports and tariff receipts. See [the investigation](claude-cost-parity.md) for evidence and current validation.
