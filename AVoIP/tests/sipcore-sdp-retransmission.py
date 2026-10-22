#!/usr/bin/env python3
"""Exercise initial and late SIPCore 200 SDP copies through the core reply route.

Uses loopback UDP SIP peers and a deterministic fake NG RTPEngine. This proves
the Kamailio route rewrites every forwarded copy without a second TM rewrite;
it does not claim production RTPEngine allocates identical ICE/DTLS details.
"""
import argparse
import json
from pathlib import Path
import re
import runpy
import socket
import subprocess
import tempfile
import threading
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-image", required=True, help="Pinned Kamailio 6.1 image")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
rendered = subprocess.check_output([
    "helm", "template", "core-home1-talos-prod", str(root / "AVoIP"),
    "--namespace", "core-prod", "-f", str(root / "AVoIP/tests/fixtures/wss-ha-registrar.yaml"),
])
objects = json.loads(subprocess.check_output(["yq", "-s", "."], input=rendered))
configs = [obj["data"]["kamailio.cfg"] for obj in objects if obj and
           obj.get("kind") == "ConfigMap" and
           "internal-wss-config" in obj.get("metadata", {}).get("name", "")]
assert len(configs) == 1
block = runpy.run_path(str(Path(__file__).with_name("sipcore-info-routing.py")))["block"]
reply = block(configs[0], "reply_route ")
reply, count = re.subn(
    r'\$proto == "tls" && \$Rp == 5062 &&\s*\$hdr\(Record-Route\) =~ "[^"]+"',
    '$proto == "udp" && $Rp == PROXY_PORT', reply)
assert count == 1


def udp():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(5)
    return sock


def receive(sock, prefix):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            data = sock.recv(65535)
        except socket.timeout:
            continue
        if data.startswith(prefix):
            return data
    raise TimeoutError(f"No {prefix!r} message")


def headers(data):
    head, body = data.split(b"\r\n\r\n", 1)
    fields = {}
    for line in head.split(b"\r\n")[1:]:
        name, value = line.split(b":", 1)
        fields.setdefault(name.lower(), []).append(value.strip())
    return fields, body


offer_sdp = (b"v=0\r\no=- 1 1 IN IP4 192.0.2.10\r\ns=-\r\nc=IN IP4 192.0.2.10\r\n"
             b"t=0 0\r\nm=audio 30108 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n")
original_sdp = (b"v=0\r\no=- 2 1 IN IP4 198.51.100.20\r\ns=-\r\nc=IN IP4 198.51.100.20\r\n"
                b"t=0 0\r\nm=audio 10060 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n")
rewritten_sdp = (b"v=0\r\no=- 2 1 IN IP4 192.0.2.63\r\ns=-\r\nc=IN IP4 192.0.2.63\r\n"
                 b"t=0 0\r\nm=audio 11072 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n")

client, uas, ng, reserve = udp(), udp(), udp(), udp()
proxy_port = reserve.getsockname()[1]
reserve.close()
stop = threading.Event()
media_commands = []


def ng_peer():
    ng.settimeout(0.2)
    while not stop.is_set():
        try:
            data, peer = ng.recvfrom(65535)
        except socket.timeout:
            continue
        cookie, command = data.split(b" ", 1)
        if b"4:ping" in command:
            result = b"d6:result4:ponge"
        else:
            media_commands.append(command)
            result = b"d6:result2:ok3:sdp" + str(len(rewritten_sdp)).encode() + b":" + rewritten_sdp + b"e"
        ng.sendto(cookie + b" " + result, peer)


thread = threading.Thread(target=ng_peer, daemon=True)
thread.start()
reply = reply.replace("PROXY_PORT", str(proxy_port))
with tempfile.TemporaryDirectory(prefix="sipcore-sdp-") as directory:
    cfg = Path(directory) / "kamailio.cfg"
    cfg.write_text(f'''debug=0
log_stderror=yes
fork=no
children=1
disable_tcp=yes
auto_aliases=no
listen=udp:127.0.0.1:{proxy_port}
loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "pv.so"
loadmodule "rr.so"
loadmodule "siputils.so"
loadmodule "textops.so"
loadmodule "nathelper.so"
loadmodule "xlog.so"
loadmodule "rtpengine.so"
modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:{ng.getsockname()[1]}")
request_route {{
  t_on_reply("CORE");
  if (has_body("application/sdp")) rtpengine_manage("replace-origin external internal address-family=IP4");
  if (!t_relay()) sl_reply_error();
  exit;
}}
{reply}
onreply_route[CORE] {{ return; }}
''')
    with (Path(directory) / "runtime.log").open("w+") as log:
        process = subprocess.Popen([
            "podman", "run", "--rm", "--network=host", "--entrypoint=kamailio",
            "-v", f"{directory}:{directory}:Z", args.runtime_image,
            "-n", "1", "-f", str(cfg),
        ], stdout=log, stderr=log)
        try:
            time.sleep(4)
            assert process.poll() is None, "Kamailio SDP harness failed to start"
            uas.settimeout(0.5)
            for attempt in range(20):
                probe = (f"OPTIONS sip:uas@127.0.0.1:{uas.getsockname()[1]} SIP/2.0\r\n"
                         f"Via: SIP/2.0/UDP 127.0.0.1:{client.getsockname()[1]};branch=z9hG4bK-ready-{attempt}\r\n"
                         "From: <sip:test@localhost>;tag=ready\r\nTo: <sip:uas@localhost>\r\n"
                         f"Call-ID: sipcore-sdp-ready-{attempt}\r\nCSeq: 1 OPTIONS\r\n"
                         "Max-Forwards: 5\r\nContent-Length: 0\r\n\r\n")
                client.sendto(probe.encode(), ("127.0.0.1", proxy_port))
                try:
                    if uas.recv(65535).startswith(b"OPTIONS "):
                        break
                except socket.timeout:
                    continue
            else:
                raise TimeoutError("Kamailio SDP harness did not forward a readiness probe")
            uas.settimeout(5)
            invite = (f"INVITE sip:uas@127.0.0.1:{uas.getsockname()[1]} SIP/2.0\r\n"
                      f"Via: SIP/2.0/UDP 127.0.0.1:{client.getsockname()[1]};branch=z9hG4bK-sdp-regression\r\n"
                      "From: <sip:7101@localhost>;tag=client-tag\r\n"
                      "To: <sip:67@localhost>\r\nCall-ID: sipcore-sdp-retransmission\r\n"
                      "CSeq: 2 INVITE\r\nMax-Forwards: 10\r\n"
                      f"Contact: <sip:7101@127.0.0.1:{client.getsockname()[1]}>\r\n"
                      f"Content-Type: application/sdp\r\nContent-Length: {len(offer_sdp)}\r\n\r\n")
            client.sendto(invite.encode() + offer_sdp, ("127.0.0.1", proxy_port))
            forwarded = receive(uas, b"INVITE ")
            fh, _ = headers(forwarded)
            response_lines = [b"SIP/2.0 200 OK"]
            for name in (b"via", b"from", b"to", b"call-id", b"cseq"):
                for value in fh[name]:
                    if name == b"to":
                        value += b";tag=uas-tag"
                    response_lines.append(name + b": " + value)
            response_lines.extend([f"Contact: <sip:67@127.0.0.1:{uas.getsockname()[1]}>".encode(),
                                   b"Content-Type: application/sdp",
                                   f"Content-Length: {len(original_sdp)}".encode()])
            response = b"\r\n".join(response_lines) + b"\r\n\r\n" + original_sdp
            bodies = []
            for _ in range(2):
                uas.sendto(response, ("127.0.0.1", proxy_port))
                received = receive(client, b"SIP/2.0 200")
                _, body = headers(received)
                bodies.append(body)
                time.sleep(0.15)
            assert bodies == [rewritten_sdp, rewritten_sdp], "Answer SDP changed or escaped media rewriting"
            assert len(media_commands) == 3, "Expected one offer and one answer per wire copy"
            print("PASS: initial and retransmitted 200 carry identical rewritten SDP; no extra offer")
        except Exception:
            log.seek(0)
            print(log.read()[-3000:])
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            stop.set()
            thread.join(timeout=1)
            client.close()
            uas.close()
            ng.close()
