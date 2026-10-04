# LLM Usage

[![CI](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml/badge.svg)](https://github.com/RunGuitarMan/llm-usage-widget/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RunGuitarMan/llm-usage-widget)](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest)

A native macOS app for local coding-agent token usage and estimated costs. It includes Statistics, session and chat inspection, model breakdowns, a daily budget, a menu bar summary and desktop widgets. English and Russian are supported.

## Install

Requires **macOS 26+ on Apple Silicon**, Node.js LTS and `ccusage`. Install Node.js from [nodejs.org](https://nodejs.org/en/download), then the tested CLI version:

```sh
npm install -g --prefix "$HOME/.local" ccusage@20.0.26
```

Download the ZIP from the [latest release](https://github.com/RunGuitarMan/llm-usage-widget/releases/latest), extract it and move **LLM Usage.app** to Applications. Releases are ad-hoc signed, without notarization: if macOS blocks a trusted download, use **System Settings → Privacy & Security → Open Anyway**.

The app starts in the menu bar. Keep it running for updates; add widgets through macOS **Edit Widgets**. It uses local agent logs, so browser-only chats are not included. Costs are estimates. The default update mode is **Claude only**; enable **All agents** in Settings for Codex, Gemini and other sources supported by the installed CLI.

## Build

Requires Xcode or Command Line Tools with **macOS SDK 26+**, plus Python 3. No third-party Swift packages are required.

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

Open a PR to `main` with a typed title:

- `feat: …` for new functionality → **minor**, e.g. `1.4.2 → 1.5.0`.
- `fix: …` for a bug fix → **patch**, e.g. `1.4.2 → 1.4.3`.
- Maintenance types such as `docs:` and `ci:` also produce a patch.

After **Tests** passes, squash-merge using the PR title. CI tests the merged commit, calculates the version, builds the app and widget, and publishes a ZIP and checksum. No manual version edit or tag is needed. See [Releases](docs/releases.md) for supported titles and retries.
