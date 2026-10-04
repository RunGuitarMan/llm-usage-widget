Download the ZIP below and move **LLM Usage.app** to Applications.

- **Chat usage and timing (#13):** inspect request and prompt token totals, estimated costs, costliest requests, tool calls and recorded timing for Claude Code, Codex and Gemini. Shared requests and verified replay history avoid duplicate charges; missing prices and incomplete timing stay explicit.
- **Unified Statistics (#16):** browse the top three sessions or expand the searchable, sortable list on the same screen. Date selection, the session inspector and widget links preserve the selected session through filtering and repeated navigation.
- **Reliable refresh and history:** manual refresh immediately updates the refresh policy. Late responses cannot replace newer reports, yesterday stays consistent with history and widgets, and clock corrections no longer stall refresh or freeze historical totals.
- **Accurate accounting and recovery:** fix Claude streaming deduplication, Codex pricing tiers, per-category model attribution and validation of cached amounts. Available tariffs remain usable when their disk cache cannot be written, and damaged tariff receipts recover on the next report.
- **Safer transcript loading and local upgrades:** preserve valid messages around damaged JSON entries and full SQLite text/IDs, bound historical report caching and multi-file OpenCode reads, and terminate CLI descendants on timeout/cancellation. The source installation script verifies a fresh bundle before replacing an older copy and restores it if replacement fails.
- Requires **macOS 26+ on Apple Silicon** and Node.js with `ccusage`.
- Includes the menu bar app and desktop widget extension.
- Ad-hoc signed, without Apple notarization. For a trusted download, use **System Settings → Privacy & Security → Open Anyway** if macOS blocks it.
- `SHA256SUMS.txt` contains the ZIP's SHA-256 checksum.

See the [installation guide](https://github.com/RunGuitarMan/llm-usage-widget#install-a-ready-made-app) for CLI setup and widget instructions.
