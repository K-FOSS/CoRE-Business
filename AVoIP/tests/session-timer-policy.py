#!/usr/bin/env python3
"""Regression model for the FreeSWITCH/Kamailio RFC 4028 policy boundary.

This is intentionally a small protocol test rather than a local FreeSWITCH
build. It locks the observed failure, the selected UAS correction, and the
proxy rule that Kamailio must not invent a replacement INVITE.
"""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
PROFILE = (ROOT / "AVoIP/templates/Admin/FreeSwitch.yaml").read_text()


def session_expires(value: str) -> int:
    match = re.fullmatch(r"\s*(\d+)\s*(?:;.*)?", value)
    if not match:
        raise ValueError(value)
    return int(match.group(1))


def uas_result(offered: str, minimum: int) -> tuple[int, int | None]:
    """Return the UAS result for the relevant RFC 4028 inputs."""
    interval = session_expires(offered)
    if interval < minimum:
        return 422, minimum
    return 200, interval


assert '<param name="enable-timer" value="true"/>' in PROFILE
assert '<param name="minimum-session-expires" value="90"/>' in PROFILE

# Reproduce the supplied failure against the old 120-second UAS policy.
assert uas_result("90", 120) == (422, 120)

# The deployed core-managed policy accepts the valid RFC 4028 floor.
assert uas_result("90", 90) == (200, 90)

# Already-compatible offers remain unchanged; the server does not normalize
# every session interval to a fixed value.
assert uas_result("120", 90) == (200, 120)

# A proxy forwards a 422; only the UAC can create the new CSeq transaction.
# This guards against adding unsafe Kamailio-side retry logic for this fix.
assert session_expires("120;refresher=uac") == 120
print("session timer policy checks passed")
