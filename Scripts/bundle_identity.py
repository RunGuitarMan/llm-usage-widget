"""Stable installed identity; local builds cannot take over released widgets."""
import re

RELEASE_BUNDLE_ID = "local.ClaudeUsage.Development"
LOCAL_BUNDLE_ID = "local.ClaudeUsage.Local"


def app_bundle_id(channel, override=None):
    if channel not in ("release", "development"):
        raise ValueError("Unknown build channel")
    identifier = override or (RELEASE_BUNDLE_ID if channel == "release" else LOCAL_BUNDLE_ID)
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier):
        raise ValueError("Expected a reverse-DNS app bundle identifier")
    if channel == "release" and identifier != RELEASE_BUNDLE_ID:
        raise ValueError("A release must preserve the installed bundle identifier")
    if channel == "development" and identifier == RELEASE_BUNDLE_ID:
        raise ValueError("A development build cannot register as the installed release")
    return identifier
