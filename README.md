# LLM Usage

[![CI](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml/badge.svg)](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RunGuitarMan/llm-usage-widget)](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest)

A native macOS app for local coding-agent token usage and estimated costs. It includes Statistics, session and chat inspection, model breakdowns, a daily budget, a menu bar summary and desktop widgets. English and Russian are supported.

## Install

Requires **macOS 26+ on Apple Silicon**. A pinned native `ccusage` is included; Node.js, npm and a separate CLI installation are unnecessary.

Download the ZIP from the [latest release](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest), extract it and move **LLM Usage.app** to Applications. Releases are ad-hoc signed, without notarization: if macOS blocks a trusted download, use **System Settings → Privacy & Security → Open Anyway**.

On first launch, approve use of the bundled calculation component and choose the update policy. This introduction appears automatically only once, even if you choose **Later**; you can enable the component in Settings afterward. Automatic checks, downloads and installation are selected by default; nothing runs until you consent. Settings also offers download-and-ask and manual modes. Automatic installation shows a 15-second countdown with a **Later** action; download-and-ask never installs on quit.

The app starts in the menu bar. Keep it running for updates; add widgets through macOS **Edit Widgets**. It uses local agent logs, so browser-only chats are not included. Costs are estimates. The default update mode is **Claude only**; enable **All agents** in Settings for Codex, Gemini and other sources supported by the bundled CLI.

## Build

Requires Xcode or Command Line Tools with **macOS SDK 26+**, plus Python 3.12+. The build downloads the checksum-pinned ccusage binary and Sparkle framework from `Configuration/Dependencies.json`; subsequent builds reuse a verified cache.

```sh
bash Scripts/build-local.sh
open 'build/LLM Usage.app'
```

To install the built app and register its widgets, quit the older copy and run `bash Scripts/install-local.sh`. The destination is `~/Applications/LLM Usage.app`.

Toolchain selection, Xcode signing, repository layout and data handling are in [Development](docs/development.md).

## Test

```sh
bash Scripts/check.sh
bash Scripts/check-icons.sh
python3 -m unittest discover -s Scripts -p 'test_*.py' -v
```

With full Xcode selected, also run `swift test`. For interactive UI review, run `bash Scripts/manual-review.sh`; this uses the real app with synthetic data and a private development catalogue. Notes survive restarts. The catalogue is excluded from ordinary and release builds.

See [Testing](docs/testing.md) for focused checks, saved reports and system-widget verification. After adding or removing Swift files, regenerate the Xcode project with `python3 Scripts/generate_project.py`.

## Release

Every PR must manually increase `version` in [`.github/release.json`](.github/release.json) above the current `main` version. Choose any higher `MAJOR.MINOR.PATCH`; PR titles do not determine it. Required **Tests** rejects unchanged or lower versions.

Merge as many PRs as needed. Merging runs checks but **does not publish a release**. When ready, open **GitHub → Actions → Release → Run workflow** on **main**. It tests the selected commit, then builds and publishes its repository version, ZIP, checksum and signed update feed. The app and widget always embed that exact version, including local builds.

See [Releases](docs/releases.md) for the full workflow, version checks and retries.
