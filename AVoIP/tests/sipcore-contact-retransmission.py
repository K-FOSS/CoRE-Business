#!/usr/bin/env python3
"""Check that retransmitted browser replies cannot erase the TOPOS alias.

--runtime uses a local Kamailio 6.1.4 with matching db_sqlite.so and its shipped
schema. All endpoints and the temporary database are isolated from production.
The WS listener condition alone is adapted to UDP loopback for the harness;
the actual rendered core reply route and TOPOS code process the responses.
"""
import argparse
import json
from pathlib import Path
import re
import runpy
import socket
import sqlite3
import subprocess
import tempfile
import time


def inspect(config, block):
    reply = block(config, "reply_route ")
    assert '$proto == "tls" && $Rp == 5062' in reply
    assert '$(hfl(Via)[-1]) =~ "^SIP/2.0/WSS"' in reply
    assert '$var(sipcore_client_reply) == 1' in reply
    assert '!is_method("REGISTER")' in reply
    assert 'is_present_hf("Contact")' in reply
    assert 'set_contact_alias("1")' in reply
    assert 'return;' in reply
    assert 'rtpengine_manage("$var(sipcore_answer_flags)")' in reply
    assert 't_relay(' not in reply
    for name in ("SIPCORE_ASTERISK_REPLY", "SIPCORE_WS_REPLY"):
        assert 'set_contact_alias("1")' not in block(config, f"onreply_route[{name}]")
    frontend = block(config, "route[FROM_SIPCORE]")
    assert frontend.count('set_contact_alias("1")') == 2
    assert frontend.count('add_contact_alias("$tcp(c_si)", "$tcp(c_sp)", "tls")') == 2
    assert 'loadmodule "tcpops.so"' in config
    assert 'nat_uac_test(64)' not in frontend
    return reply


def exercise(reply, schema_sql, negative=False, runtime_image=None, public_contact_only=False):
    def udp():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.settimeout(0.5)
        return sock

    def headers(data):
        result = {}
        for line in data.split(b"\r\n\r\n")[0].split(b"\r\n")[1:]:
            name, value = line.split(b":", 1)
            result.setdefault(name.lower(), []).append(value.strip())
        return result

    def receive(sock, prefix, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data = sock.recv(65535)
            except socket.timeout:
                continue
            if data.startswith(prefix):
                return data
        raise TimeoutError("Synthetic SIP exchange timed out")

    ast, browser, reserve = udp(), udp(), udp()
    port = reserve.getsockname()[1]
    reserve.close()
    # Keep all remaining statements of the production reply route intact.
    reply, count = re.subn(
        r'\$proto == "tls" && \$Rp == 5062',
        f'$proto == "udp" && $Rp == {port}', reply)
    assert count == 1
    # This harness isolates Contact/TOPOS behavior and sends no SDP. The
    # production media callback is separately guarded by the TLS render test.
    block = runpy.run_path(str(Path(__file__).with_name("sipcore-info-routing.py")))["block"]
    media = block(reply, 'if ($var(sipcore_client_reply) == 1 && has_body("application/sdp"))')
    reply = reply.replace(media, "", 1)
    if negative:
        # Reproduce the original bug with the same body in TM's named route.
        core_reply = ""
        transaction_reply = reply.replace("reply_route ", "onreply_route[BROWSER] ", 1)
    else:
        core_reply = reply
        transaction_reply = "onreply_route[BROWSER] { return; }"

    with tempfile.TemporaryDirectory(prefix="sipcore-topos-") as directory:
        db = Path(directory) / "topos.db"
        connection = sqlite3.connect(db)
        connection.execute("CREATE TABLE version (table_name TEXT PRIMARY KEY, table_version INTEGER)")
        connection.executescript(schema_sql)
        connection.commit()
        cfg = Path(directory) / "kamailio.cfg"
        record_route = (f'record_route_preset("127.0.0.1:{port};lr;r2=on", '
                        f'"127.0.0.2:{port};lr;r2=on");' if public_contact_only else
                        f'record_route_preset("127.0.0.1:{port};lr");')
        cfg.write_text(f'''debug=0
log_stderror=yes
fork=no
children=1
disable_tcp=yes
auto_aliases=no
alias="127.0.0.2:{port}"
listen=udp:127.0.0.1:{port}
loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "pv.so"
loadmodule "rr.so"
loadmodule "siputils.so"
loadmodule "textops.so"
loadmodule "nathelper.so"
loadmodule "xlog.so"
loadmodule "db_sqlite.so"
loadmodule "topos.so"
modparam("topos", "db_url", "sqlite://{db}")
modparam("topos", "contact_mode", 1)
modparam("topos", "cparam_name", "tps")
modparam("topos", "rr_update", 1)
request_route {{
  if (has_totag()) {{
    if (!loose_route()) {{ sl_send_reply("481", "No Dialog"); exit; }}
    if ($du == $null) {{
      handle_ruri_alias();
      if ($rc != 1) {{ if (!is_method("ACK")) sl_send_reply("404", "Alias Lost"); exit; }}
    }}
  }} else {{
    {record_route}
    t_on_reply("BROWSER");
  }}
  if (!t_relay()) sl_reply_error();
  exit;
}}
{core_reply}
{transaction_reply}
''')
        def request(method, seq, uri, route=None, tagged=False):
            fields = [f"{method} {uri} SIP/2.0",
                      f"Via: SIP/2.0/UDP 127.0.0.1:{ast.getsockname()[1]};branch=z9hG4bK-{method}-{seq}",
                      "From: <sip:ast@localhost>;tag=ast-tag",
                      "To: <sip:browser@localhost>" + (";tag=browser-tag" if tagged else ""),
                      "Call-ID: synthetic-topos-alias", f"CSeq: {seq} {method}", "Max-Forwards: 10"]
            if route:
                fields.append("Route: " + route)
            if method == "INVITE":
                fields.append(f"Contact: <sip:ast@127.0.0.1:{ast.getsockname()[1]}>")
            return ("\r\n".join(fields) + "\r\nContent-Length: 0\r\n\r\n").encode()

        with (Path(directory) / "runtime.log").open("w+") as log:
            command = ["kamailio", "-n", "1", "-f", str(cfg)]
            if runtime_image:
                command = ["podman", "run", "--rm", "--network=host", "--entrypoint=kamailio",
                           "-v", f"{directory}:{directory}:Z", runtime_image,
                           "-n", "1", "-f", str(cfg)]
            process = subprocess.Popen(command, stdout=log, stderr=log)
            try:
                time.sleep(4.0 if runtime_image else 0.5)
                assert process.poll() is None, "Kamailio/SQLite harness failed to start"
                ast.sendto(request("INVITE", 1, f"sip:browser@127.0.0.1:{browser.getsockname()[1]}"), ("127.0.0.1", port))
                ih = headers(receive(browser, b"INVITE "))
                fields = [b"SIP/2.0 200 OK"]
                for name in (b"via", b"from", b"to", b"call-id", b"cseq", b"record-route"):
                    for value in ih.get(name, []):
                        if name == b"to":
                            value += b";tag=browser-tag"
                        fields.append(name + b": " + value)
                fields += [f"Contact: <sip:browser@127.0.0.1:{browser.getsockname()[1]};transport=udp>".encode(),
                           b"Content-Length: 0"]
                response = b"\r\n".join(fields) + b"\r\n\r\n"
                browser.sendto(response, ("127.0.0.1", port))
                answer = headers(receive(ast, b"SIP/2.0 200"))
                uri = answer[b"contact"][0].decode().strip("<>")
                if public_contact_only:
                    assert f"@127.0.0.2:{port}" in uri, "TOPOS emitted the owner-side client-facing Contact"
                    browser.sendto(response, ("127.0.0.1", port))
                    repeated = headers(receive(ast, b"SIP/2.0 200"))
                    assert repeated[b"contact"] == answer[b"contact"], "TOPOS changed the public Contact on retransmission"
                    print("PASS: final post-TOPOS Contact uses public inbound RR on initial and retransmitted 200")
                    return
                route = answer.get(b"record-route", [b""])[0].decode() or None

                for index, method in enumerate(("ACK", "ACK", "BYE")):
                    if index == 1:
                        browser.sendto(response, ("127.0.0.1", port))
                        receive(ast, b"SIP/2.0 200")
                    contact = connection.execute("SELECT b_contact FROM topos_d").fetchone()[0]
                    expected = not (negative and index > 0)
                    assert ("alias=" in contact) == expected, "Stored Contact alias changed unexpectedly"
                    seq = 1 if method == "ACK" else 2
                    ast.sendto(request(method, seq, uri, route, True), ("127.0.0.1", port))
                    if not expected:
                        if method == "ACK":
                            try:
                                receive(browser, b"ACK ", timeout=0.6)
                            except TimeoutError:
                                pass
                            else:
                                raise AssertionError("Old handler unexpectedly delivered the later ACK")
                        else:
                            receive(ast, b"SIP/2.0 404")
                        continue
                    delivered = receive(browser, (method + " ").encode())
                    h = headers(delivered)
                    assert h[b"call-id"] == [b"synthetic-topos-alias"]
                    assert h[b"cseq"] == [f"{seq} {method}".encode()]
                    assert h[b"from"] == [b"<sip:ast@localhost>;tag=ast-tag"]
                    assert h[b"to"] == [b"<sip:browser@localhost>;tag=browser-tag"]
                    if method == "BYE":
                        reply_fields = [b"SIP/2.0 200 OK"]
                        for name in (b"via", b"from", b"to", b"call-id", b"cseq"):
                            reply_fields.extend(name + b": " + v for v in h[name])
                        browser.sendto(b"\r\n".join(reply_fields) + b"\r\nContent-Length: 0\r\n\r\n", ("127.0.0.1", port))
                        returned = headers(receive(ast, b"SIP/2.0 200"))
                        assert returned[b"cseq"] == [b"2 BYE"]
                        assert returned[b"call-id"] == [b"synthetic-topos-alias"]
                print("PASS: old transaction-only handler reproduces alias loss" if negative else
                      "PASS: core reply handler retains TOPOS alias after retransmitted 200; subsequent ACK and BYE arrive with original dialog identifiers")
            except Exception:
                log.seek(0)
                print(log.read()[-2500:])
                raise
            finally:
                process.terminate()
                process.wait(timeout=5)
                connection.close()
                for sock in (ast, browser):
                    sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--runtime", action="store_true")
    parser.add_argument("--runtime-image", help="Use this pinned Kamailio image with Podman instead of a host binary")
    parser.add_argument("--schema", type=Path, default=Path("/usr/share/kamailio/db_sqlite/topos-create.sql"))
    args = parser.parse_args()
    block = runpy.run_path(str(Path(__file__).with_name("sipcore-info-routing.py")))["block"]
    if args.config:
        configs = [args.config.read_text()]
    else:
        root = Path(__file__).resolve().parents[2]
        rendered = subprocess.check_output(["helm", "template", "core-home1-talos-prod", str(root / "AVoIP"),
                                            "--namespace", "core-prod", "-f", str(root / "AVoIP/tests/fixtures/wss-ha-pilot.yaml")])
        objects = json.loads(subprocess.check_output(["yq", "-s", "."], input=rendered))
        configs = [o["data"]["kamailio.cfg"] for o in objects if o and o.get("kind") == "ConfigMap"
                   and "route[FROM_SIPCORE]" in o.get("data", {}).get("kamailio.cfg", "")]
    assert configs
    schema_sql = None
    if args.runtime:
        if args.runtime_image:
            schema_sql = subprocess.check_output([
                "podman", "run", "--rm", "--entrypoint=sh", args.runtime_image,
                "-c", "cat /usr/share/kamailio/db_sqlite/topos-create.sql",
            ], text=True)
        else:
            schema_sql = args.schema.read_text()
    for config in configs:
        reply = inspect(config, block)
        if args.runtime:
            exercise(reply, schema_sql, negative=True, runtime_image=args.runtime_image)
            exercise(reply, schema_sql, runtime_image=args.runtime_image)
            exercise(reply, schema_sql, runtime_image=args.runtime_image, public_contact_only=True)
    print("PASS: same-source client Contacts are forcibly aliased, including retransmitted 2xx responses before TM")


if __name__ == "__main__":
    main()
