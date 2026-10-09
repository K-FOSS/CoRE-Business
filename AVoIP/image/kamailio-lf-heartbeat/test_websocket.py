#!/usr/bin/env python3
"""Black-box regression for the patched Kamailio SIP WebSocket module.

Run against the test Kamailio listener built from Containerfile. This uses
only Python's standard library so CI does not need a third-party WS client.
"""

import argparse
import base64
import os
import socket
import ssl
import struct
import time
import urllib.parse


def read_exact(sock, size):
    chunks = bytearray()
    while len(chunks) < size:
        part = sock.recv(size - len(chunks))
        if not part:
            raise AssertionError("WebSocket closed before expected response")
        chunks.extend(part)
    return bytes(chunks)


def read_frame(sock):
    first, second = read_exact(sock, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if second & 0x80 else b""
    payload = read_exact(sock, length)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return first & 0x0F, bool(first & 0x80), payload


def send_frame(sock, opcode, payload=b"", final=True):
    mask = os.urandom(4)
    size = len(payload)
    first = (0x80 if final else 0) | opcode
    if size < 126:
        header = bytes((first, 0x80 | size))
    elif size < 65536:
        header = bytes((first, 0x80 | 126)) + struct.pack("!H", size)
    else:
        header = bytes((first, 0x80 | 127)) + struct.pack("!Q", size)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(header + mask + masked)


def expect_crlf(sock):
    opcode, final, payload = read_frame(sock)
    assert opcode == 1 and final and payload == b"\r\n", (opcode, final, payload)


def connect(url, origin, host_header):
    parsed = urllib.parse.urlparse(url)
    secure = parsed.scheme == "wss"
    port = parsed.port or (443 if secure else 80)
    deadline = time.monotonic() + 5
    while True:
        try:
            sock = socket.create_connection(
                (parsed.hostname, port), timeout=max(0.1, deadline - time.monotonic())
            )
            break
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    if secure:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=parsed.hostname)
    sock.settimeout(5)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    request = (
        f"GET {path} HTTP/1.1\r\nHost: {host_header}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Protocol: sip\r\nOrigin: {origin}\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = bytearray()
    while not response.endswith(b"\r\n\r\n"):
        response.extend(read_exact(sock, 1))
        assert len(response) < 16384, "oversized handshake response"
    assert response.startswith(b"HTTP/1.1 101"), response.decode("latin1")
    headers = response.decode("latin1").lower()
    assert "sec-websocket-protocol: sip\r\n" in headers, response.decode("latin1")
    return sock


def expect_closed(sock):
    sock.settimeout(5)
    try:
        first = sock.recv(1)
    except (ConnectionResetError, BrokenPipeError):
        return
    if not first:
        return
    assert first[0] == 0x88, f"expected connection close, received frame byte {first!r}"
    second = read_exact(sock, 1)[0]
    size = second & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(sock, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if second & 0x80 else b""
    payload = read_exact(sock, size)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    assert len(payload) <= 125, "unexpected oversized WebSocket close payload"
    try:
        assert sock.recv(1) == b"", "server sent more data after WebSocket close"
    except (ConnectionResetError, BrokenPipeError):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url", help="ws:// or wss:// listener URL, normally ending /ws")
    parser.add_argument("--host", required=True, help="expected HTTP Host")
    parser.add_argument("--origin", required=True, help="allowed Origin")
    parser.add_argument("--disabled", action="store_true", help="assert the pre-patch behavior")
    args = parser.parse_args()

    sock = connect(args.url, args.origin, args.host)
    if args.disabled:
        send_frame(sock, 1, b"\n\n")
        expect_closed(sock)
        print("PASS: disabled compatibility preserves parser-failure connection handling")
        return

    for _ in range(5):
        send_frame(sock, 1, b"\n\n")
        expect_crlf(sock)
        time.sleep(0.05)

    # The message is exactly two LF bytes after WebSocket continuation reassembly.
    send_frame(sock, 1, b"\n", final=False)
    send_frame(sock, 0, b"\n", final=True)
    expect_crlf(sock)

    send_frame(sock, 1, b"\r\n")
    expect_crlf(sock)

    send_frame(sock, 9, b"probe")
    opcode, final, payload = read_frame(sock)
    assert opcode == 10 and final and payload == b"probe", (opcode, final, payload)

    options = (
        "OPTIONS sip:heartbeat-test SIP/2.0\r\n"
        "Via: SIP/2.0/WS test.invalid;branch=z9hG4bK-lf-heartbeat\r\n"
        "From: <sip:test@invalid>;tag=heartbeat\r\n"
        "To: <sip:heartbeat-test@invalid>\r\n"
        "Call-ID: lf-heartbeat-regression\r\nCSeq: 1 OPTIONS\r\n"
        "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
    ).encode("ascii")
    send_frame(sock, 1, options)
    opcode, final, response = read_frame(sock)
    assert opcode == 1 and final and response.startswith(b"SIP/2.0 200"), response

    # Only LF/LF is special. Other malformed text must retain normal parser behavior.
    send_frame(sock, 1, b"\n \n")
    expect_closed(sock)
    print("PASS: repeated and fragmented LF/LF, SIP traffic, CRLF and Ping/Pong")
    print("PASS: other malformed payload still follows the existing parser failure path")


if __name__ == "__main__":
    main()
