#!/usr/bin/env python3
"""Guard the native-TLS dialog, media and owner-flow contracts in rendered cfg.

The separate sipcore-contact-retransmission.py --runtime harness checks the
actual post-TOPOS Contact on the wire. This check covers the production TLS
branches that the loopback UDP harness cannot execute without Envoy.
"""
import argparse
import json
from pathlib import Path
import re
import runpy
import socket
import subprocess
import tempfile
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-image", help="Pinned Kamailio 6.1 image for string-evaluation regression")
args = parser.parse_args()


root = Path(__file__).resolve().parents[2]
rendered = subprocess.check_output([
    "helm", "template", "core-home1-talos-prod", str(root / "AVoIP"),
    "--namespace", "core-prod", "-f",
    str(root / "AVoIP/tests/fixtures/wss-ha-registrar.yaml"),
])
objects = json.loads(subprocess.check_output(["yq", "-s", "."], input=rendered))
configs = [obj["data"]["kamailio.cfg"] for obj in objects if obj and
           obj.get("kind") == "ConfigMap" and
           "internal-wss-config" in obj.get("metadata", {}).get("name", "")]
assert len(configs) == 1
config = configs[0]
modules = re.findall(r'^loadmodule "([^"]+)"', config, re.MULTILINE)
assert modules[0] == 'tls.so', 'TLS must initialize before forked registrar DB clients'
block = runpy.run_path(str(Path(__file__).with_name("sipcore-info-routing.py")))["block"]
frontend = block(config, "route[FROM_SIPCORE]")
backend = block(config, "route[FROM_SIPCORE_ASTERISK]")
reply = block(config, "reply_route ")
named_reply = block(config, "onreply_route[SIPCORE_WS_REPLY]")
relay = block(config, "route[PRIVATE_RELAY]")
device_auth = block(config, "route[PRIVATE_AUTH_DEVICE]")

# TOPOS must derive the client-facing Contact from the public inbound RR, and
# preserve the private outbound owner RR for cross-replica restoration.
assert re.search(r'record_route_preset\(\s*"SIPCORE_OWNER_POD\.[^\"]+:5063;transport=tls;lr;r2=on",\s*'
                 r'"sipcore\.mylogin\.space:8443;transport=tls;lr;r2=on"', frontend)
assert 'modparam("topos", "contact_mode", 1)' in config
assert 'modparam("topos", "rr_update", 1)' in config
assert 'stage=frontend-owner-hop' in frontend
assert 'X-Core-Frontend-Owner-Forward' in frontend and 'remove_hf("X-Core-Frontend-Owner-Forward")' in frontend
assert 'stage=frontend-owner-received' in backend
assert backend.index('route(FROM_SIPCORE);') < backend.index('check_flow_token()')

# The alias names the accepted Envoy peer, and only the owner may select its
# local socket. A missing or replaced flow terminates before t_relay.
assert 'add_contact_alias("$tcp(c_si)", "$tcp(c_sp)", "tls")' in frontend
assert '$sht(sipcore_tls_dialog=>$ci) = $conid;' in frontend
assert 'tcp_get_conid("$var(sipcore_flow_peer)", "$var(sipcore_flow_conid)")' in backend
assert 'tcp_conid_alive("$var(sipcore_flow_conid)")' in backend
assert 'ine $var(sipcore_flow_conid)' in backend
assert backend.index('tcp_set_otcpid("$var(sipcore_flow_conid)")') < backend.index('tcp_set_otcpid_flag(1)')
assert backend.index('tcp_set_otcpid_flag(1)') < backend.rindex('route(PRIVATE_RELAY);')
assert 'stage=tls-owner-flow-gone' in backend and '430", "TLS Flow Failed' in backend
assert 'sipcore_tls_dialog=>size=8;autoexpire=86400' in config

# Core reply_route runs for late 2xx when TM's named onreply route does not.
# One call per wire copy; no second transformation in the TM callback.
assert '$Rp == 5062' in reply and '$hdr(Record-Route) =~' in reply
assert reply.count('rtpengine_manage("$var(sipcore_answer_flags)")') == 1
assert 'rtpengine_manage(' not in named_reply
assert 'WebRTC ' in reply and '$proto == "ws"' in frontend
assert 'if ($proto == "ws") {' in frontend
assert '$var(sipcore_media_flags) = "WebRTC " + $var(sipcore_media_flags);' in frontend
assert '$var(sipcore_media_flags) = "SDES-nonew " + $var(sipcore_media_flags);' in frontend
assert frontend.index('SDES-nonew ') < frontend.index('rtpengine_manage("$var(sipcore_media_flags)")')
assert 'stage=frontend-offer-media-applied' in frontend
assert 'stage=frontend-answer-media-applied' in reply

# Force string semantics for the side marker in both request and send routes.
source = (root / "AVoIP/templates/Kamailio/_sip-private.tpl").read_text()
assert 'if ($var(side) eq "sipcore" && is_method("ACK|INFO"))' in source
assert 'if ($var(side) eq "sipcore" && is_method("INFO"))' in config
assert not re.search(r'\$var\(side\)\s*(?:==|!=)\s*"sipcore"', config)
assert 'if ($var(side) eq "sipcore" && is_method("INFO"))' in relay

# Device Digest belongs to the frontend realm only. Once accepted, it must
# not leak to FreeSWITCH and trigger a second authentication challenge.
assert device_auth.index('proxy_authorize(') < device_auth.index('consume_credentials();')
assert device_auth.index('consume_credentials();') < device_auth.index('remove_hf("Authorization");')
assert device_auth.index('remove_hf("Authorization");') < device_auth.index('remove_hf("Proxy-Authorization");')
assert device_auth.index('remove_hf("Proxy-Authorization");') < device_auth.index('$var(auth_device) = 1;')

# Registrar SQL must match the shipped subscriber schema.
jobs = [obj for obj in objects if obj and obj.get("kind") == "CronJob" and
        "reg-sync-7101" in obj.get("metadata", {}).get("name", "")]
assert len(jobs) == 1
assert "email_address" not in json.dumps(jobs[0])
print("PASS: public TOPOS Contact, replica owner, pinned TLS flow, retransmitted media, string types and registrar SQL render")

if args.runtime_image:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.bind(("127.0.0.1", 0))
        client.settimeout(4)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="sipcore-string-eq-") as directory:
            cfg = Path(directory) / "kamailio.cfg"
            cfg.write_text(f'''debug=0
log_stderror=yes
fork=no
children=1
disable_tcp=yes
listen=udp:127.0.0.1:{port}
loadmodule "pv.so"
loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "siputils.so"
loadmodule "textops.so"
loadmodule "xlog.so"
request_route {{
  $var(side) = 0;
  if ($var(side) eq "sipcore" && is_method("ACK|INFO")) {{ xlog("L_ERR", "wrong side\\n"); }}
  $var(side) = "sipcore";
  if ($var(side) eq "sipcore") {{ xlog("L_ERR", "SIPCORE_STRING_EQ_PASS\\n"); }}
  sl_send_reply("200", "OK");
  exit;
}}
''')
            with (Path(directory) / "kamailio.log").open("w+") as log:
                process = subprocess.Popen([
                    "podman", "run", "--rm", "--network=host", "--entrypoint=kamailio",
                    "-v", f"{directory}:{directory}:Z", args.runtime_image,
                    "-n", "1", "-f", str(cfg),
                ], stdout=log, stderr=log)
                try:
                    time.sleep(5)
                    assert process.poll() is None, "Kamailio string harness failed to start"
                    request = (f"OPTIONS sip:7101@127.0.0.1:{port} SIP/2.0\r\n"
                               f"Via: SIP/2.0/UDP 127.0.0.1:{client.getsockname()[1]};branch=z9hG4bK-string-eq\r\n"
                               "From: <sip:test@localhost>;tag=string-eq\r\n"
                               "To: <sip:7101@localhost>\r\n"
                               "Call-ID: sipcore-string-eq\r\nCSeq: 1 OPTIONS\r\n"
                               "Content-Length: 0\r\n\r\n")
                    client.sendto(request.encode(), ("127.0.0.1", port))
                    assert client.recv(4096).startswith(b"SIP/2.0 200"), "No response from runtime harness"
                    time.sleep(0.2)
                    log.seek(0)
                    output = log.read()
                    assert "SIPCORE_STRING_EQ_PASS" in output
                    assert 'automatic string to int conversion for "sipcore" failed' not in output
                    print("PASS: Kamailio evaluates numeric and string side markers without integer conversion")
                except Exception:
                    log.seek(0)
                    print(log.read()[-2500:])
                    raise
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
