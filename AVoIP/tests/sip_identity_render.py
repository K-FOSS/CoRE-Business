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
    parser.add_argument("--cluster-name", required=True)
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
    public_host = args.site_host
    public_socket = "public_tls"
    assert f'listen=tls:0.0.0.0:5061 advertise "{public_host}":5061 name "{public_socket}"' in kam
    assert 'advertise "66.165.222.101":5061' not in kam
    assert f'listen=tls:0.0.0.0:5062 advertise "{host(kam_name)}":5062 name "private_tls"' in kam
    assert 'alias="sip.resolvemy.host:5061"' in kam
    assert f'alias="{args.site_host}:5061"' in kam
    assert f'{host(kam_name)}:5062;transport=tls' in kam
    assert f'sip:{host(fs_name)}:5061;transport=tls' in kam
    assert f'{public_host}:5061;transport=tls;sn={public_socket}' in kam
    assert 'sips:sip.resolvemy.host:5061;transport=tls;sn=' not in kam
    assert 'add_rr_param(";r2=on")' in kam
    assert 'loadmodule "corex.so"' in kam
    assert 'loadmodule "ndb_redis.so"' in kam
    assert 'loadmodule "topos.so"' in kam
    assert 'loadmodule "topos_redis.so"' in kam
    assert 'modparam("topos", "contact_mode", 3)' in kam
    assert 'TOPOS_REDIS_SERVER' in kam
    assert 'remove_hf_match("Record-Route"' not in kam
    assert 'subst_hf("Record-Route"' not in kam
    assert 'subst_hf("Contact"' not in kam
    assert 'remove_hf_idx("Record-Route", "0")' not in kam
    assert 'if (!loose_route_mode("1"))' in kam
    assert 'modparam("siptrace", "trace_mode", 1)' in kam
    assert 'SIP ack ingress pod=$env(POD_NAME)' in kam
    assert 'SIP ack send pod=$env(POD_NAME)' in kam
    assert 'SIP dialog reject pod=$env(POD_NAME)' in kam
    assert 'set_send_socket_name("private_tls")' in kam
    assert 'set_send_socket_name("public_tls")' in kam
    assert '$proto == "tls" && $Rp == 5061' in kam
    assert '$proto == "tls"' in kam and '$Rp == 5062' in kam
    assert f'sip:{host(fs_name)}:5061;transport=tls' in kam
    assert f'$xavp(tls=>server_name) = "{host(fs_name)}"' in kam
    assert 'SIP ack send pod=$env(POD_NAME)' in kam
    assert '66.165.222.101' not in kam
    assert 'sdp=$rb' not in kam
    assert 'listen=tcp:0.0.0.0:5061' not in kam
    assert 'sn=public_tcp' not in kam

    public_route = document(items, "TLSRoute", "-kamailio")
    assert public_route["spec"]["parentRefs"][0]["sectionName"] == "sips-tls"
    assert public_route["spec"]["hostnames"] == [public_host]
    policy = document(items, "BackendTrafficPolicy", "-kamailio-tls-proxy-protocol")
    assert policy["spec"]["targetRefs"][0]["kind"] == "TLSRoute"
    service_ports = document(items, "Service", "-kamailio")["spec"]["ports"]
    public_port = next(port for port in service_ports if port["port"] == 5061)
    assert public_port["targetPort"] == "tls-public"
    kamailio_deployment = document(items, "Deployment", "-kamailio")
    assert kamailio_deployment["spec"]["replicas"] == 3
    assert kamailio_deployment["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 1
    assert kamailio_deployment["spec"]["strategy"]["rollingUpdate"]["maxSurge"] == 0
    kamailio_pod = kamailio_deployment["spec"]["template"]["spec"]
    assert kamailio_pod["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
    assert kamailio_pod["topologySpreadConstraints"][0]["whenUnsatisfiable"] == "DoNotSchedule"
    pdb = document(items, "PodDisruptionBudget", "-kamailio")
    assert pdb["spec"]["minAvailable"] == 2
    kamailio_container = next(
        c for c in kamailio_deployment["spec"]["template"]["spec"]["containers"]
        if c["name"] == "kamailio"
    )
    assert "kamcmd -s unixs:/tmp/kamailio_ctl core.uptime" in str(kamailio_container["readinessProbe"])
    assert any(e["name"] == "POD_NAME" and e["valueFrom"]["fieldRef"]["fieldPath"] == "metadata.name"
               for e in kamailio_container["env"])
    freeswitch_deployment = document(items, "Deployment", "-freeswitch")
    assert freeswitch_deployment["spec"]["replicas"] == 1
    policy = next(item for item in items if item and item.get("kind") == "NetworkPolicy"
                  and item["spec"]["podSelector"]["matchLabels"].get("app.kubernetes.io/controller") == "kamailio")
    ingress = policy["spec"]["ingress"]
    assert any(rule.get("ports") == [{"port": 5061, "protocol": "TCP"}] and "from" in rule
               for rule in ingress)
    assert any(rule.get("ports") == [{"port": 5062, "protocol": "TCP"}]
               and rule["from"][0]["podSelector"]["matchLabels"]["app.kubernetes.io/controller"] == "freeswitch"
               for rule in ingress)

    homer_oidc = document(items, "Workspace", "avoip-homer-oidc")
    oidc_variables = homer_oidc["spec"]["forProvider"]["varmap"]
    assert oidc_variables["provider_name"] == (
        f"{oidc_variables['display_name']} {args.cluster_name}"
    )
    assert "name                 = var.provider_name" in homer_oidc["spec"]["forProvider"]["module"]

    configs = document(items, "ConfigMap", "-freeswitch-configs")["data"]
    assert f"external_sip_ip={host(kam_name)}" in configs["vars.xml"]
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
    assert not any(a.get("application") in ("fax_detect", "rxfax") for a in post_answer.findall(".//action"))
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

    for component, service_name in (("freeswitch", fs_name), ("asterisk", ast_name)):
        service = document(items, "Service", f"-{component}")
        assert "wan-mode" not in service["metadata"].get("labels", {})
        assert "lan-mode" not in service["metadata"].get("labels", {})
        assert "annotations" not in service["metadata"]
        assert service["spec"]["type"] == "ClusterIP"
    public_service = document(items, "Service", "-kamailio")
    assert "annotations" not in public_service["metadata"]
    assert "wan-mode" not in public_service["metadata"].get("labels", {})
    assert "lan-mode" not in public_service["metadata"].get("labels", {})
    assert {port["port"] for port in public_service["spec"]["ports"]} == {5061, 5062}
    assert not any(item and item.get("kind") == "Service" and item["metadata"]["name"].endswith("-freeswitch-rtp")
                   for item in items)
    topos_secret = next(item for item in items if item and item.get("kind") == "ExternalSecret"
                        and item["metadata"]["name"] == "avoip-kamailio-topos")
    assert topos_secret["spec"]["data"][0]["remoteRef"]["key"].endswith("/Creds")
    assert "db=51" in topos_secret["spec"]["target"]["template"]["data"]["server"]
    rtp = document(items, "Deployment", "-rtpengine")
    command = str(next(container for container in rtp["spec"]["template"]["spec"]["containers"] if container["name"] == "rtpengine"))
    assert f"!{args.media_address}" in command
    assert "--homer-protocol=tcp" in command
    assert ":9061" in command and "--homer-enable-ng" in command
    print("SIP identity, TLS, HEP, and DID render checks passed")


if __name__ == "__main__":
    main()
