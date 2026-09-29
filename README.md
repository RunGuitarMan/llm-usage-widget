# LLM Usage

[![CI](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml/badge.svg)](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RunGuitarMan/llm-usage-widget)](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest)

A native macOS 26 app that shows token usage and estimated costs from local AI coding agents, including Claude Code, Codex and Gemini CLI. Available sources depend on your installed `ccusage` CLI.

## What it does

- Shows daily totals, a seven-day spending chart, and usage by model and session.
- Filters by date, source and model; searches sessions and local chat transcripts.
- Shows today's spending in the menu bar and in Summary, Sessions and Trend desktop widgets.
- Supports a daily budget marker, automatic background refresh, launch at login, and English/Russian text.

## How it works

The app runs `ccusage session --json` to read supported local usage logs. It calculates totals and saves small JSON snapshots that the WidgetKit extension reads. The app runs in the menu bar without a Dock icon, including while its dashboard is open. Keep the app running for fresh widget data; closing its window leaves it running in the menu bar. Click the amount to open or close the usage popover, which includes buttons for the dashboard and Settings. Right-click (or Control-click) the amount for a menu with **Quit LLM Usage**.

Usage and transcripts are processed locally. `ccusage` can fetch model prices online, so costs are estimates, not invoices. Browser chats and activity without supported local logs are not included. The Swift app has no third-party package dependencies.

## Install a ready-made app

Download the ZIP from the [latest GitHub release](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest) and extract it.

If you received `LLM Usage.app`, you do not need to build it. You need **macOS 26+**; the tested build is for **Apple Silicon (M-series)**. Intel builds have not been tested.

1. Install **Node.js LTS** using the macOS installer from [nodejs.org](https://nodejs.org/en/download). It includes npm. If Node.js and a working `ccusage` are already installed, skip to step 3.
2. Open Terminal and install the tested `ccusage` version into your user folder:

   ```sh
   npm install -g --prefix "$HOME/.local" ccusage@20.0.26
   "$HOME/.local/bin/ccusage" --version
   ```

   The version command should print `20.0.26`. The app automatically searches this folder; no `sudo` or shell configuration is needed with the Node.js installer above.
3. Copy `LLM Usage.app` to **Applications** and open it. If macOS blocks this trusted copy, go to **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. macOS remembers the exception for later launches ([Apple's instructions](https://support.apple.com/en-us/102445)).
4. Add LLM Usage through macOS **Edit Widgets**. Keep the app running for fresh data. If it cannot find `ccusage`, choose its executable in the app's Settings.

**No `jq`, Python, Xcode, Command Line Tools or Homebrew is needed to run the ready-made app.** Node.js is needed for the npm-installed `ccusage`; other libraries come with macOS. Usage data requires local logs from a supported coding agent you have used.

## Sharing the app without a paid Apple account

You can share the locally signed `.app` in a ZIP without joining the Apple Developer Program. Recipients do not need certificates, an Apple developer account or to sign/rebuild it themselves, but may need the **Open Anyway** step above on each Mac. This is not a warning-free release: widgets have been tested locally, but installation on another Mac has not yet been verified. For distribution without that manual security exception, the publisher needs Developer ID signing and Apple notarization for each release ([Apple's distribution guide](https://developer.apple.com/developer-id/)).

## Build from source

First install Node.js and `ccusage` as described above. Building also requires Xcode or Command Line Tools with **macOS SDK 26+**, and Python 3. From the repository folder, run:

```sh
bash Scripts/build-local.sh
open 'build/LLM Usage.app'
```

This builds and verifies a locally signed development app with its widget extension. If automatic CLI discovery fails, choose the `ccusage` executable in Settings.

To install it in `~/Applications` and register the widgets:

```sh
bash Scripts/install-local.sh
open "$HOME/Applications/LLM Usage.app"
```

Quit any older running copy first. Then add LLM Usage from macOS **Edit Widgets**. To try sample data, quit the app and run `open 'build/LLM Usage.app' --args --demo`.

Scripts prefer `DEVELOPER_DIR`, then `build/AppleTools26`, then the system toolchain. If only an older SDK is installed, `python3 Scripts/prepare-local-toolchain.py` can download Apple's tools locally (macOS 26.2+, about 800 MB to download and 4 GB extracted). It does not replace the system tools.

For an Xcode build, open `LLMUsage.xcodeproj`, select **LLMUsage → My Mac**, and configure signing for both the app and widget. Set your team and a registered, shared App Group in the ignored `Configuration/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
LLM_USAGE_APP_GROUP = group.com.yourname.LLMUsage
```

Use bundle identifiers available to your team. Xcode builds share data through that App Group; the default local development build grants the widget read-only access to its snapshot files.

## Working on the repository

Changes go through pull requests to protected `main`. Each PR runs the **Tests** check; after merge and successful checks, GitHub Actions automatically publishes the next release starting at **v1.0**. See [CI and releases](Documentation/Releases.md) for versioning, artifacts and retry instructions.

- `LLMUsage/`: app screens, shared models, data services, widget, resources and tests.
- `Scripts/`: build, install, validation and asset-generation tools.
- `Configuration/`: shared build settings; keep personal signing settings in `Local.xcconfig`.
- `Package.swift`: core test harness. The app and widget are built by the Xcode project or scripts.

Run the regression checks after changes:

```sh
bash Scripts/check.sh
bash Scripts/check-icons.sh
```

`check.sh` also typechecks the app and widget. The [audit regression checks](Documentation/RegressionChecks.md) cover shared transcript records, background search cancellation, historical cache expiry, day labels and dated widget links; the same scenarios run in XCTest.

With full Xcode selected, run `swift test` for the core XCTest suite, or test the configured app target:

```sh
xcodebuild -project LLMUsage.xcodeproj -scheme LLMUsage \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test
```

After adding or removing Swift files, run `python3 Scripts/generate_project.py`. Make project structure changes in that generator: it overwrites the project and shared scheme.

The icon's source is `LLMUsage/Shared/BrandGeometry.swift`; local builds regenerate its SVGs and asset catalog. Run `bash Scripts/render-previews.sh` for UI previews in `build/Previews` (optional filters: `--widgets`, `--menus`, `--language=en`).

Commit source, tests, build configuration and required app resources. Keep build products, caches and generated preview images in ignored `build/`. If you use the local toolchain, preserve `build/AppleTools26` when cleaning build outputs. Existing `ClaudeUsage` bundle IDs, storage keys and URL aliases preserve compatibility with earlier installs.
