Download the ZIP below, extract it and move **LLM Usage.app** to Applications.

- Requires **macOS 26+ on Apple Silicon**. Native ccusage is bundled; Node.js and npm are not required.
- Includes the menu bar app and desktop widget extension.
- Ad-hoc signed without notarization. If macOS blocks a trusted copy, use **System Settings → Privacy & Security → Open Anyway**.
- `SHA256SUMS.txt` contains the ZIP checksum.

See [installation instructions](https://github.com/RunGuitarMan/llm-usage-widget#install) for first-launch setup.

On first launch, approve the bundled calculation component and choose automatic updates, download-and-ask, or manual updates. The default is automatic, with a visible countdown before restarting. Updates verify signed metadata and archives. Ad-hoc signing and the first-install Gatekeeper instructions still apply.

## Changes in 1.6.1

- Correct Claude cache-write and normal/Batch pricing, and include validated background usage from saved session totals while preserving custom tariffs.
- Add opt-in local Claude telemetry with per-session storage, retention, live reception status and chat request/cost comparisons. Telemetry does not add charges a second time.
- Preview Claude settings changes before explicit consent. Only missing environment variables are added; conflicting values cancel the write. Every change includes a backup, concurrent-change checks and atomic saving.
- Export selected telemetry sessions or periods as a local ZIP with fresh identifier/model aliases. Chat text, tool contents, headers, settings and unknown fields are excluded before storage.

Telemetry supports OTLP HTTP/JSON logs. Collection can be partial when the app is stopped or a launcher overrides the environment. ZIP exports retain timestamps and numeric usage values.
