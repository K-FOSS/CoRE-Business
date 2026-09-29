#!/usr/bin/env python3
"""Assert the shared Gateway L4 listener map and SIPS no-SNI fallback render."""

import json
import pathlib
import subprocess
import sys


def main(path):
    result = subprocess.run(
        ["yq", "-s", ".", str(path)], capture_output=True, text=True, check=True
    )
    resources = json.loads(result.stdout)
    gateway = next(
        item for item in resources
        if item and item.get("kind") == "Gateway" and item["metadata"]["name"] == "main-gw"
    )
    listeners = {listener["name"]: listener for listener in gateway["spec"]["listeners"]}
    expected = {
        "sip-udp": (5060, "UDP", "UDPRoute"),
        "sip-tcp": (5060, "TCP", "TCPRoute"),
        "sips-tls": (5061, "TLS", "TLSRoute"),
        "smtp-tcp": (25, "TCP", "TCPRoute"),
        "submission-tcp": (587, "TCP", "TCPRoute"),
        "submissions-tls": (465, "TLS", "TLSRoute"),
        "imap-tcp": (143, "TCP", "TCPRoute"),
        "imaps-tls": (993, "TLS", "TLSRoute"),
    }
    for name, (port, protocol, route_kind) in expected.items():
        listener = listeners[name]
        assert (listener["port"], listener["protocol"]) == (port, protocol), (name, listener)
        assert route_kind in [kind["kind"] for kind in listener["allowedRoutes"]["kinds"]], (name, listener)

    sips = listeners["sips-tls"]
    assert sips["tls"]["mode"] == "Passthrough"
    fallback = next(
        item for item in resources
        if item and item.get("kind") == "EnvoyPatchPolicy"
        and item["metadata"]["name"] == "sips-no-sni-fallback"
    )
    assert fallback["spec"]["targetRef"]["kind"] == "Gateway"
    assert fallback["spec"]["targetRef"]["name"] == "main-gw"
    patch = fallback["spec"]["jsonPatches"]
    assert len(patch) == 1
    assert patch[0]["name"] == "core-prod/main-gw/sips-tls"
    assert patch[0]["operation"] == {
        "op": "remove",
        "path": "/filter_chains/0/filter_chain_match/server_names",
    }
    assert not any(item.get("kind") == "TCPRoute" and item["metadata"]["name"].endswith("kamailio")
                   for item in resources if item)
    print("Gateway listener matrix and TLS passthrough no-SNI fallback checks passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: gateway_listener_render.py <helm-render.yaml>")
    main(pathlib.Path(sys.argv[1]))
