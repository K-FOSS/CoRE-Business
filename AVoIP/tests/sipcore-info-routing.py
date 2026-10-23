#!/usr/bin/env python3
"""Render checks; --runtime also exercises extracted routes with Kamailio 6.1.

The runtime harness binds ephemeral loopback ports and uses a fake NG peer and
SIP UAS. It never contacts the deployed RTPEngine, Asterisk, or a real mailbox.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time


ICE = 'if ($var(sipcore_content_type) == "application/trickle-ice-sdpfrag" && has_body())'


def block(text, marker):
    """Extract script blocks, ignoring braces in comments and quoted strings."""
    start = text.index(marker)
    opening = text.index("{", start + len(marker))
    depth, quoted, comment, escaped = 0, False, False, False
    for i in range(opening, len(text)):
        c = text[i]
        if comment:
            comment = c != "\n"
        elif quoted:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quoted = False
        elif c == "#":
            comment = True
        elif c == '"':
            quoted = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError("Unclosed script block")


def inspect(config):
    assert 'has_body("application/trickle-ice-sdpfrag")' not in config
    classifier = block(config, "route[SIPCORE_CONTENT_TYPE]")
    assert '$(cT{s.select,0,;}{s.trim}{s.tolower})' in classifier
    assert "sl_send_reply" not in classifier and "rtpengine_" not in classifier
    handlers = []
    for name in ("FROM_SIPCORE", "FROM_SIPCORE_ASTERISK"):
        route = block(config, f"route[{name}]")
        assert route.index("loose_route()") < route.index("route(SIPCORE_CONTENT_TYPE)")
        handler = block(route, ICE)
        assert 'if (!is_method("INFO"))' in handler
        assert handler.count("rtpengine_info()") == 1
        assert route.count("rtpengine_info()") == 1
        assert route.index(handler) < route.rindex("route(PRIVATE_RELAY)")
        # SDP manipulation remains restricted to the known SDP media type.
        sdp = block(route, 'if (has_body("application/sdp"))')
        assert "rtpengine_manage(" in sdp
        handlers.append(handler)
    return classifier, handlers


def bound_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.1)
    return sock


def headers(message):
    head, body = message.split(b"\r\n\r\n", 1)
    result = {}
    for line in head.split(b"\r\n")[1:]:
        key, value = line.split(b":", 1)
        result.setdefault(key.lower(), []).append(value.strip())
    return result, body


def exercise(classifier, handler):
    ng, uas, client, reserve = [bound_socket() for _ in range(4)]
    proxy_port = reserve.getsockname()[1]
    reserve.close()
    stop = threading.Event()
    media_calls, forwarded = [], []
    errors = []

    def media_peer():
        while not stop.is_set():
            try:
                data, peer = ng.recvfrom(65535)
            except socket.timeout:
                continue
            cookie, command = data.split(b" ", 1)
            if b"4:ping" in command:
                reply = b"d6:result4:ponge"
            else:
                media_calls.append(command)
                reply = b"d6:result2:oke"
            ng.sendto(cookie + b" " + reply, peer)

    def downstream():
        while not stop.is_set():
            try:
                data, peer = uas.recvfrom(65535)
            except socket.timeout:
                continue
            h, body = headers(data)
            forwarded.append((h, body))
            # Demonstrate that even a downstream error is relayed unchanged.
            status = b"415 Unsupported Media Type" if h.get(b"content-type", [b""])[0] == b"application/x-other" else b"200 OK"
            lines = [b"SIP/2.0 " + status]
            for name in (b"via", b"from", b"to", b"call-id", b"cseq"):
                lines.extend(name + b": " + value for value in h[name])
            uas.sendto(b"\r\n".join(lines) + b"\r\nContent-Length: 0\r\n\r\n", peer)

    for target in (media_peer, downstream):
        def run(target=target):
            try:
                target()
            except Exception as error:
                errors.append(error)
        threading.Thread(target=run, daemon=True).start()

    with tempfile.TemporaryDirectory(prefix="sipcore-info-") as directory:
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
loadmodule "textops.so"
loadmodule "xlog.so"
loadmodule "rr.so"
loadmodule "siputils.so"
loadmodule "rtpengine.so"
modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:{ng.getsockname()[1]}")
request_route {{
  if (!has_totag() || !loose_route()) {{
    sl_send_reply("481", "Call Does Not Exist");
    exit;
  }}
  route(SIPCORE_CONTENT_TYPE);
  {handler}
  if (!t_relay()) sl_reply_error();
  exit;
}}
{classifier}
''')
        with (Path(directory) / "runtime.log").open("w+") as log:
            process = subprocess.Popen(["kamailio", "-n", "1", "-f", str(cfg)], stdout=log, stderr=log)
            try:
                time.sleep(0.5)
                assert process.poll() is None, "Kamailio harness failed to start"
                # No real PIN or DTMF body is recorded by the harness.
                cases = [
                    ("application/dtmf-relay", "INFO", False, 200),
                    ("Application/DTMF-Relay; charset=utf-8", "INFO", False, 200),
                    ("application/trickle-ice-sdpfrag", "INFO", True, 200),
                    ("Application/Trickle-ICE-SDPFrag; charset=utf-8", "INFO", True, 200),
                    ("application/x-other", "INFO", False, 415),
                    ("application/trickle-ice-sdpfrag-extra", "INFO", False, 200),
                    ("text/plain", "INFO", False, 200),
                    (None, "INFO", False, 200),
                    ("application/trickle-ice-sdpfrag", "UPDATE", False, 488),
                ]
                for seq, (ctype, method, ice, status) in enumerate(cases, 1):
                    body = b"a=ice-ufrag:synthetic\r\na=ice-pwd:synthetic-test-only\r\n" if ice else b"synthetic-body\r\n"
                    if ctype is None:
                        body = b""
                    callid = f"info-regression-{seq}"
                    fields = [
                        f"{method} sip:test@127.0.0.1:{uas.getsockname()[1]} SIP/2.0",
                        f"Via: SIP/2.0/UDP 127.0.0.1:{client.getsockname()[1]};branch=z9hG4bK-test-{seq}",
                        "From: <sip:synthetic@localhost>;tag=from-test",
                        "To: <sip:synthetic@localhost>;tag=to-test",
                        f"Call-ID: {callid}", f"CSeq: {seq} {method}",
                        f"Route: <sip:127.0.0.1:{proxy_port};lr>",
                        "Max-Forwards: 10",
                    ]
                    if ctype:
                        fields.append("Content-Type: " + ctype)
                    fields.append(f"Content-Length: {len(body)}")
                    before_media, before_sip = len(media_calls), len(forwarded)
                    client.sendto("\r\n".join(fields).encode() + b"\r\n\r\n" + body, ("127.0.0.1", proxy_port))
                    deadline = time.monotonic() + 4
                    while True:
                        try:
                            response = client.recv(65535)
                        except socket.timeout:
                            assert time.monotonic() < deadline, f"No final SIP response in case {seq}"
                            continue
                        if not response.startswith(b"SIP/2.0 100"):
                            break
                    assert response.startswith(f"SIP/2.0 {status} ".encode()), (seq, response.split(b"\r\n")[0])
                    assert len(media_calls) - before_media == int(ice), "Unexpected RTPEngine invocation"
                    if ice:
                        command = media_calls[-1]
                        assert b"8:fragment" in command
                        assert callid.encode() in command
                        assert b"from-test" in command and b"to-test" in command
                    response_headers, _ = headers(response)
                    assert response_headers[b"call-id"] == [callid.encode()]
                    assert response_headers[b"cseq"] == [f"{seq} {method}".encode()]
                    relayed = status != 488 and not ice
                    assert len(forwarded) - before_sip == int(relayed), "Unexpected SIP forwarding"
                    if relayed:
                        h, received_body = forwarded[-1]
                        assert received_body == body
                        assert h[b"call-id"] == [callid.encode()]
                        assert h[b"cseq"] == [f"{seq} {method}".encode()]
                        assert h[b"from"] == [b"<sip:synthetic@localhost>;tag=from-test"]
                        assert h[b"to"] == [b"<sip:synthetic@localhost>;tag=to-test"]
                        if ctype:
                            assert h[b"content-type"] == [ctype.encode()]
                assert not errors, errors
                print("PASS: real Kamailio MIME classification, ICE invocation, dialog relay, body/identifier preservation, downstream 200/415")
            except Exception:
                log.seek(0)
                print(log.read()[-5000:])
                raise
            finally:
                process.terminate()
                process.wait(timeout=5)
                stop.set()
                for sock in (ng, uas, client):
                    sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Already rendered SIP Core kamailio.cfg")
    parser.add_argument("--runtime", action="store_true", help="Run a local Kamailio harness")
    args = parser.parse_args()
    if args.config:
        configs = [args.config.read_text()]
    else:
        root = Path(__file__).resolve().parents[2]
        rendered = subprocess.check_output([
            "helm", "template", "core-home1-talos-prod", str(root / "AVoIP"),
            "--namespace", "core-prod", "-f", str(root / "AVoIP/tests/fixtures/wss-ha.yaml"),
            "--set", "avoipAdmin.bridgedCalls.enabled=false",
        ])
        resources = subprocess.check_output(["yq", "-s", "."], input=rendered)
        configs = [r["data"]["kamailio.cfg"] for r in json.loads(resources)
                   if r and r.get("kind") == "ConfigMap" and "route[FROM_SIPCORE]" in r.get("data", {}).get("kamailio.cfg", "")]
    assert configs, "No SIP Core configuration found"
    for config in configs:
        classifier, handlers = inspect(config)
        if args.runtime:
            for handler in handlers:
                exercise(classifier, handler)
    print("PASS: both INFO interception points follow dialog validation and only exact ICE bodies reach rtpengine_info")


if __name__ == "__main__":
    main()
