#!/usr/bin/env python3
"""Exercise rendered Kamailio reply routes in an isolated loopback process.

Run locally with --config <rendered kamailio.cfg> --context <context>
--namespace <namespace> --deployment <Kamailio deployment>. Requires the
existing kamailio and Python-capable netshoot containers. Production processes
are untouched: only the fixture's listeners, backend, ACL and NG endpoint are
substituted. No phone calls or live RTPEngine sessions are created.
"""
import argparse
import json
import pathlib
import re
import socket
import subprocess
import sys
import threading
import time
import uuid

PUBLIC = '66.165.222.103'
PUBLIC_PORT = 11020


def encode(value):
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b':' + value
    if isinstance(value, dict):
        return b'd' + b''.join(encode(k) + encode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(type(value))


def decode(data, pos=0):
    if data[pos:pos+1] in (b'd', b'l'):
        dictionary = data[pos:pos+1] == b'd'
        values = []
        pos += 1
        while data[pos:pos+1] != b'e':
            item, pos = decode(data, pos)
            values.append(item)
        return (dict(zip(values[::2], values[1::2])) if dictionary else values), pos + 1
    if data[pos:pos+1] == b'i':
        end = data.index(b'e', pos)
        return int(data[pos+1:end]), end + 1
    end = data.index(b':', pos)
    size = int(data[pos:end])
    return data[end+1:end+1+size], end + 1 + size


class SipStream:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = b''

    def read(self, timeout=5):
        self.sock.settimeout(timeout)
        while True:
            if b'\r\n\r\n' in self.buffer:
                headers, rest = self.buffer.split(b'\r\n\r\n', 1)
                length = int(re.search(br'(?im)^Content-Length:\s*(\d+)', headers)[1])
                if len(rest) >= length:
                    self.buffer = rest[length:]
                    return headers.decode(), rest[:length].decode()
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError('SIP connection closed')
            self.buffer += chunk

    def final(self):
        for _ in range(10):
            headers, body = self.read()
            if headers.startswith('SIP/2.0 200'):
                return headers, body
        raise AssertionError('No 200 OK received')


def harness():
    fail_answers = threading.Event()
    commands = []
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 12223))

    def ng_server():
        while True:
            data, peer = udp.recvfrom(65536)
            cookie, payload = data.split(b' ', 1)
            message, _ = decode(payload)
            command = message[b'command'].decode()
            commands.append(command)
            if command == 'ping':
                response = {'result': 'pong'}
            elif command in ('offer', 'answer'):
                if command == 'answer' and fail_answers.is_set():
                    response = {'result': 'error', 'error-reason': 'Injected test failure'}
                else:
                    body = message[b'sdp'].decode()
                    address = PUBLIC if command == 'answer' else '192.0.2.20'
                    body = re.sub(r'(?m)^c=IN IP4 [^\r\n]+', 'c=IN IP4 ' + address, body)
                    body = re.sub(r'(?m)^m=audio \d+', 'm=audio ' + str(PUBLIC_PORT), body)
                    response = {'result': 'ok', 'sdp': body}
            else:
                response = {'result': 'ok'}
            udp.sendto(cookie + b' ' + encode(response), peer)

    threading.Thread(target=ng_server, daemon=True).start()
    backend = socket.socket()
    backend.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    backend.bind(('127.0.0.1', 16061))
    backend.listen()
    backend.settimeout(15)
    caller = None
    for _ in range(100):
        try:
            caller = socket.create_connection(('127.0.0.1', 15061), timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    assert caller is not None, 'Test Kamailio listener did not start'
    time.sleep(0.5)
    caller_port = caller.getsockname()[1]
    call_id = 'avoip-reply-regression-' + uuid.uuid4().hex
    body = 'v=0\r\no=fixture 1 1 IN IP4 192.0.2.10\r\ns=fixture\r\nc=IN IP4 192.0.2.10\r\nt=0 0\r\nm=audio 18000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n'
    headers = [
        'INVITE sip:fax@127.0.0.1 SIP/2.0',
        f'Via: SIP/2.0/TCP 127.0.0.1:{caller_port};branch=z9hG4bK{call_id};rport',
        'From: <sip:fixture@localhost>;tag=fixture-from',
        'To: <sip:fax@localhost>', f'Call-ID: {call_id}', 'CSeq: 1 INVITE',
        f'Contact: <sip:fixture@127.0.0.1:{caller_port};transport=tcp>',
        'Max-Forwards: 70', 'Content-Type: application/sdp',
        f'Content-Length: {len(body)}', '', body,
    ]
    caller.sendall('\r\n'.join(headers).encode())
    downstream, _ = backend.accept()
    request_headers, _ = SipStream(downstream).read()
    response_headers = ['SIP/2.0 200 OK']
    for line in request_headers.split('\r\n')[1:]:
        if line.lower().startswith(('via:', 'from:', 'to:', 'call-id:', 'cseq:', 'record-route:')):
            response_headers.append(line + (';tag=fixture-to' if line.lower().startswith('to:') else ''))
    private_body = body.replace('192.0.2.10', '172.20.50.82').replace('18000', '11000')
    response_headers += ['Contact: <sip:fax@127.0.0.1:16061;transport=tls>',
                         'Content-Type: application/sdp', f'Content-Length: {len(private_body)}']
    response = ('\r\n'.join(response_headers) + '\r\n\r\n' + private_body).encode()
    upstream = SipStream(caller)
    outputs = []
    for delay in (0, 0.2, 2, 4):
        time.sleep(delay)
        downstream.sendall(response)
        response_headers, received = upstream.final()
        contact = re.search(r'(?im)^Contact:\s*<([^>]+)>', response_headers)
        assert contact, 'Contact missing from a forwarded 200 OK'
        print(json.dumps({'reply': len(outputs) + 1,
                          'contact': contact[1],
                          'connection': re.search(r'(?m)^c=([^\r\n]+)', received)[1],
                          'media': re.search(r'(?m)^m=([^\r\n]+)', received)[1]}), flush=True)
        assert contact[1].startswith('sips:'), 'Insecure SIP Contact escaped in a 200 OK'
        assert f'c=IN IP4 {PUBLIC}\r\n' in received, 'Unrewritten address escaped in a 200 OK'
        assert f'm=audio {PUBLIC_PORT} ' in received, 'Unrewritten RTP port escaped in a 200 OK'
        assert '172.20.50.82' not in re.search(r'(?m)^c=.*', received)[0]
        outputs.append(received)
    assert len(set(outputs)) == 1, '200 OK retransmission bodies differ'
    assert commands.count('answer') == 4, f'Reply bypassed NG answer handling: {commands}'
    fail_answers.set()
    downstream.sendall(response)
    try:
        upstream.read(timeout=2)
    except socket.timeout:
        pass
    else:
        raise AssertionError('Final SDP response escaped after RTPEngine failure')
    print(json.dumps({'forwarded_200': len(outputs), 'identical_bodies': True,
                      'connection': PUBLIC, 'audio_port': PUBLIC_PORT,
                      'failed_rewrite_dropped': True, 'ng_answers': commands.count('answer')}))


def fixture_config(source):
    cfg = source
    cfg = re.sub(r'^\s*loadmodule "(?:tls|siptrace)\.so".*\n', '', cfg, flags=re.M)
    cfg = re.sub(r'^\s*modparam\("(?:tls|siptrace)".*\n', '', cfg, flags=re.M)
    cfg = re.sub(r'^enable_tls=.*$', 'enable_tls=0', cfg, flags=re.M)
    cfg = cfg.replace('tcp_accept_haproxy=yes', 'tcp_accept_haproxy=no')
    cfg = re.sub(r'^listen=tcp:.*$', 'listen=tcp:127.0.0.1:15061 name "public_tcp"', cfg, flags=re.M)
    cfg = re.sub(r'^listen=tls:.*$', 'listen=tcp:127.0.0.1:15062 name "private_tls"', cfg, flags=re.M)
    cfg = re.sub(r'modparam\("rtpengine", "rtpengine_sock", "[^"]+"\)',
                 'modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:12223")', cfg)
    cfg = re.sub(r'\$du = "sip:[^"]+";', '$du = "sip:127.0.0.1:16061;transport=tcp";', cfg)
    cfg = cfg.replace('request_route {', 'request_route {\n  if (src_ip == 127.0.0.1) { route(FLOWROUTE_AUTHORIZED); exit; }', 1)
    return cfg


def runner(args):
    base = ['kubectl', '--context', args.context, '-n', args.namespace, 'exec', '-i',
            'deploy/' + args.deployment]
    stem = '/tmp/avoip-replies-' + uuid.uuid4().hex
    cfg = fixture_config(pathlib.Path(args.config).read_text())
    subprocess.run(base + ['-c', 'kamailio', '--', 'sh', '-c', f'cat > {stem}.cfg'],
                   input=cfg, text=True, check=True)
    subprocess.run(base + ['-c', 'kamailio', '--', 'kamailio', '-c', '-f', stem + '.cfg'], check=True)
    fixture = subprocess.Popen(base + ['-c', 'netshoot', '--', 'python3', '-', '--harness'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixture.stdin.write(pathlib.Path(__file__).read_text())
    fixture.stdin.close()
    fixture.stdin = None
    time.sleep(0.5)
    kam = subprocess.Popen(base + ['-c', 'kamailio', '--', 'kamailio', '-DD', '-E',
                                  '-m', '16', '-M', '8', '-f', stem + '.cfg', '-P', stem + '.pid'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        out, err = fixture.communicate(timeout=30)
        print(out, end='')
        print(err, end='', file=sys.stderr)
        if fixture.returncode:
            raise RuntimeError('Reply retransmission regression failed')
    finally:
        subprocess.run(base + ['-c', 'kamailio', '--', 'sh', '-c',
                               f'if [ -f {stem}.pid ]; then kill -TERM "$(cat {stem}.pid)"; fi'], check=False)
        try:
            _, log = kam.communicate(timeout=5)
            pathlib.Path(args.config + '.test.log').write_text(log)
        except subprocess.TimeoutExpired:
            kam.terminate()
        if fixture.poll() is None:
            fixture.terminate()
        subprocess.run(base + ['-c', 'kamailio', '--', 'rm', '-f', stem + '.cfg', stem + '.pid'], check=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harness', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--config')
    parser.add_argument('--context')
    parser.add_argument('--namespace', default='core-prod')
    parser.add_argument('--deployment')
    options = parser.parse_args()
    if options.harness:
        harness()
    else:
        if not all((options.config, options.context, options.deployment)):
            parser.error('--config, --context and --deployment are required')
        runner(options)
