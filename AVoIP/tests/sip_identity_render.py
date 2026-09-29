#!/usr/bin/env python3
"""Check SIP identity, TLS, HEP, and DID invariants in a Helm render."""

import argparse
import json
import pathlib
import subprocess
import xml.etree.ElementTree as ET


def documents(path):
    result = subprocess.run(
        ["yq", "-s", ".", str(path)], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def document(items, kind, suffix):
    matches = [
        item for item in items
        if item and item.get("kind") == kind and item["metadata"]["name"].endswith(suffix)
    ]
    assert len(matches) == 1, (kind, suffix, len(matches))
    return matches[0]


def extension(root, name):
    matches = root.findall(f".//extension[@name='{name}']")
    assert len(matches) == 1, (name, len(matches))
    return matches[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("render", type=pathlib.Path)
    parser.add_argument("--voice-did", required=True)
    parser.add_argument("--fax-did", required=True)
    parser.add_argument("--site-host", required=True)
    parser.add_argument("--cluster-domain", required=True)
    parser.add_argument("--media-address", default="66.165.222.103")
    args = parser.parse_args()

    manifest = args.render.read_text()
    assert "66.165.222.120" not in manifest
    items = documents(args.render)
    fs_name = document(items, "Service", "-freeswitch")["metadata"]["name"]
    ast_name = document(items, "Service", "-asterisk")["metadata"]["name"]
    kam_name = document(items, "Service", "-kamailio")["metadata"]["name"]
    namespace = document(items, "Service", "-freeswitch")["metadata"].get("namespace", "core-prod")
    host = lambda name: f"{name}.{namespace}.svc.{args.cluster_domain}"

    kam = document(items, "ConfigMap", "-kamailio-config")["data"]["kamailio.cfg"]
    public_host = "sip.resolvemy.host"
    assert f'advertise "{public_host}":5061 name "public_tcp"' in kam
    assert 'alias="sip.resolvemy.host:5061"' in kam
    assert f'alias="{args.site_host}:5061"' in kam
    assert f'{host(kam_name)}:5062;transport=tls' in kam
    assert f'sip:{host(fs_name)}:5061;transport=tls' in kam
    assert f'{public_host}:5061;transport=tls;sn=public_tcp' in kam
    assert 'add_rr_param(";r2=on")' in kam
    assert 'remove_hf_idx("Record-Route", "0")' in kam
    assert 'Flowroute receives only the public Record-Route URI' in kam
    assert f'$du = "sip:{host(fs_name)}:5061;transport=tls"' in kam
    assert 'loose_route()' in kam
    assert 'ACK fallback=no-route' not in kam
    assert 'sips?:([^@>]+)@[^>]+' in kam
    assert r'sips:\\1@sip.resolvemy.host:5061;transport=tls' in kam
    assert '66.165.222.101' not in kam

    configs = document(items, "ConfigMap", "-freeswitch-configs")["data"]
    assert f"external_sip_ip={public_host}" in configs["vars.xml"]
    assert f"private_sip_host={host(fs_name)}" in configs["vars.xml"]
    assert "network.egressIP" not in configs["vars.xml"]
    profiles = document(items, "ConfigMap", "-freeswitch-sip-configs")["data"]
    gateway = ET.fromstring(profiles["asterisk.xml"])
    params = {p.get("name"): p.get("value") for p in gateway.findall("./gateways/gateway/param")}
    assert params["from-domain"] == host(fs_name)
    assert params["proxy"] == f"{host(ast_name)}:5061;transport=tls"
    assert 'tls-verify-policy" value="subjects_out' in profiles["asterisk.xml"]
    kamailio_profile = ET.fromstring(profiles["kamailio.xml"])
    sip_params = {p.get("name"): p.get("value") for p in kamailio_profile.findall("./settings/param")}
    assert sip_params["sip-domain"] == "$${external_sip_ip}"
    assert sip_params["ext-sip-ip"] == "host:$${external_sip_ip}"
    assert sip_params["ext-sip-port"] == "5061"
    assert sip_params["tls-verify-policy"] == "subjects_out"

    dialplan = ET.fromstring(document(items, "ConfigMap", "-freeswitch-dialplan-configs")["data"]["public.xml"])
    voice = extension(dialplan, "flowroute-did")
    assert voice.find("condition").get("expression") == f"^{args.voice_did}$"
    assert any(a.get("application") == "bridge" for a in voice.findall(".//action"))
    assert not any("fax" in (a.get("application", "") + a.get("data", "")) for a in voice.findall(".//action"))
    post_answer = extension(dialplan, "did-post-answer")
    assert not any("fax" in (a.get("application", "") + a.get("data", "")) for a in post_answer.findall(".//action"))
    fax = extension(dialplan, "dedicated-fax-did")
    assert fax.find("condition").get("expression") == f"^{args.fax_did}$"
    assert [a.get("application") for a in fax.findall(".//action")][-1] == "transfer"
    receive = extension(dialplan, "fax-receive")
    assert any(a.get("application") == "rxfax" for a in receive.findall(".//action"))
    assert not any(a.get("application") == "fax_detect" for a in dialplan.findall(".//action"))

    asterisk = document(items, "ConfigMap", "-asterisk-configs")["data"]["extensions.conf"]
    assert "same => n,Echo()\n" in asterisk
    assert asterisk.count("same => n,Playback(hello-world)") == 4
    assert asterisk.index("same => n,Echo()") < asterisk.index("same => n,Playback(hello-world)")
    assert asterisk.index("same => n,Playback(hello-world)") < asterisk.index("same => n,Hangup()")

    for component, service_name in (("kamailio", kam_name), ("freeswitch", fs_name), ("asterisk", ast_name)):
        service = document(items, "Service", f"-{component}")
        annotations = service["metadata"]["annotations"]
        assert annotations["external-dns.kubernetes.io/hostname"] == host(service_name)
        assert annotations["external-dns.alpha.kubernetes.io/hostname"] == host(service_name)
        assert service["metadata"]["labels"]["wan-mode"] == "public"
        assert service["metadata"]["labels"]["lan-mode"] == "private"
        assert service["spec"]["type"] == "ClusterIP"
        cert = document(items, "Certificate", f"-{component}-sip-tls")
        assert cert["spec"]["dnsNames"] == [host(service_name)]
    rtp = document(items, "Deployment", "-rtpengine")
    command = str(next(container for container in rtp["spec"]["template"]["spec"]["containers"] if container["name"] == "rtpengine"))
    assert f"!{args.media_address}" in command
    assert "--homer-protocol=tcp" in command
    assert ":9061" in command and "--homer-enable-ng" in command
    print("SIP identity, TLS, HEP, and DID render checks passed")


if __name__ == "__main__":
    main()
