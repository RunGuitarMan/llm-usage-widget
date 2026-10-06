#!/usr/bin/env python3
"""Exercise the actual native helper with synthetic Claude transcripts only."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TOKEN_KEYS = ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens")


def check(binary, selected=None):
    cases = json.loads((ROOT / "LLMUsage/Tests/Fixtures/claude-response-boundaries.json").read_text())
    for case in cases:
        if selected and case["name"] != selected:
            continue
        with tempfile.TemporaryDirectory(prefix="claude-stream-check-") as temporary:
            root = Path(temporary)
            project = root / ".claude/projects/project"
            project.mkdir(parents=True)
            (project / "s.jsonl").write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in case["records"]))
            config = root / "ccusage.json"
            config.write_text(json.dumps({"defaults": {"pricingOverrides": {"claude-response-fixture": {
                "inputCostPerToken": .000002, "outputCostPerToken": .00001,
                "cacheCreationInputTokenCost": .0000025, "cacheReadInputTokenCost": .0000002}}}}))
            env = dict(os.environ, HOME=str(root), CLAUDE_CONFIG_DIR=str(root / ".claude"),
                       XDG_CONFIG_HOME=str(root / ".config"), XDG_CACHE_HOME=str(root / ".cache"), LOG_LEVEL="0")
            for report in ("session", "daily"):
                windows = [("20261003", "20261004", case["expected"])]
                windows += [(day, day, dict(zip(TOKEN_KEYS, values))) for day, values in case.get("days", {}).items()]
                for since, until, expected in windows:
                    result = subprocess.run([str(binary), "claude", report, "--json", "--since", since,
                        "--until", until, "--timezone", "UTC", "--mode", "calculate", "--offline",
                        "--config", str(config)], env=env, capture_output=True, text=True, check=True)
                    totals = json.loads(result.stdout)["totals"]
                    actual = {key: totals.get(key, 0) for key in TOKEN_KEYS}
                    assert actual == expected, (case["name"], report, since, until, actual, expected)
                    cost = sum(expected[key] * rate for key, rate in zip(TOKEN_KEYS, (.000002, .00001, .0000025, .0000002)))
                    assert abs(totals["totalCost"] - cost) < 1e-10, (case["name"], report, "cost")
            print("PASS", case["name"], flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "build/LLM Usage.app/Contents/Helpers/ccusage")
    parser.add_argument("--case")
    args = parser.parse_args()
    check(args.cli.resolve(), args.case)
