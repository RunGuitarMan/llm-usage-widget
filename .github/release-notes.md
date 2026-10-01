Download the ZIP below and move **LLM Usage.app** to Applications.

- **Offline Claude pricing (#10):** tariffs are refreshed and saved before each report. After a successful download, cached prices survive network failures and app restarts, and new offline usage continues to be calculated. Invalid responses do not overwrite valid prices; user pricing overrides retain priority.
- **Excluded model reference data (#11):** Models shows original tokens, cost and token breakdowns for excluded models, labeled **Excluded from totals**. Overview, Sessions, history, menu bar and widgets still exclude those amounts. Mixed sessions without a complete model breakdown remain one combined row.
- **Native sidebar appearance (#14):** Finder-style neutral selection adapts to light/dark appearance and active/inactive windows. Native keyboard navigation is preserved, and Overview uses a new grid icon.
- Requires **macOS 26+ on Apple Silicon** and Node.js with `ccusage`.
- Includes the menu bar app and desktop widget extension.
- Ad-hoc signed, without Apple notarization. For a trusted download, use **System Settings → Privacy & Security → Open Anyway** if macOS blocks it.
- `SHA256SUMS.txt` contains the ZIP's SHA-256 checksum.

See the [installation guide](https://github.com/RunGuitarMan/llm-usage-widget#install-a-ready-made-app) for CLI setup and widget instructions.
