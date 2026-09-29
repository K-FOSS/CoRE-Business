#!/usr/bin/env python3
"""Check the opt-in K8GB GSLB and Gateway API wiring in an AVoIP render."""

import json
import pathlib
import subprocess
import sys


def main():
    render = pathlib.Path(sys.argv[1])
    global_host = sys.argv[2]
    site_host = sys.argv[3]
    primary_geo_tag = sys.argv[4]
    media_address = sys.argv[5]
    items = json.loads(
        subprocess.run(
            ["yq", "-s", ".", str(render)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    routes = [item for item in items if item and item.get("kind") == "TLSRoute"]
    route = next(item for item in routes if item["spec"]["hostnames"] == [site_host])
    global_route = next(item for item in routes if item["spec"]["hostnames"] == [global_host])
    assert route["spec"]["parentRefs"][0]["sectionName"] == "sips-tls"
    assert route["metadata"]["annotations"]["external-dns.kubernetes.io/hostname"] == site_host
    assert global_route["spec"]["parentRefs"][0]["sectionName"] == "sips-tls"
    assert global_route["spec"]["rules"][0]["backendRefs"] == route["spec"]["rules"][0]["backendRefs"]

    gslb = next(item for item in items if item and item.get("kind") == "Gslb")
    assert gslb["metadata"]["annotations"]["k8gb.io/hostname"] == global_host
    assert gslb["spec"]["resourceRef"] == {
        "apiVersion": "gateway.networking.k8s.io/v1",
        "kind": "TLSRoute",
        "name": global_route["metadata"]["name"],
    }
    assert gslb["spec"]["strategy"] == {
        "type": "failover",
        "dnsTtlSeconds": 30,
        "primaryGeoTag": primary_geo_tag,
    }

    delegation = next(item for item in items if item and item.get("kind") == "ZoneDelegation")
    assert delegation["spec"] == {
        "loadBalancedZone": global_host,
        "parentZone": global_host.split(".", 1)[1],
        "dnsZoneNegTTL": 30,
        "doFinalize": False,
    }

    config = next(
        item for item in items
        if item and item.get("kind") == "ConfigMap"
        and item["metadata"]["name"].endswith("-kamailio-config")
    )
    kamailio = config["data"]["kamailio.cfg"]
    assert f'advertise "{global_host}":5061 name "public_tls"' in kamailio
    assert f'{global_host}:5061;transport=tls;sn=public_tls' in kamailio
    assert f'sips:\\\\1@{global_host}:5061;transport=tls' in kamailio
    assert "svc." in kamailio
    assert media_address in render.read_text()
    print("K8GB TLSRoute failover and global SIP identity checks passed")


if __name__ == "__main__":
    main()
