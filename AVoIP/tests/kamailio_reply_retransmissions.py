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
PUBLIC_HOST = 'sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host'


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
    backend.bind(('127.0.0.3', 16061))
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
    unauthorized = socket.socket()
    unauthorized.bind(('127.0.0.2', 0))
    unauthorized.connect(('127.0.0.1', 15061))
    unauthorized_port = unauthorized.getsockname()[1]
    unauthorized.sendall(('\r\n'.join([
        'INVITE sips:fax@127.0.0.1:5061;transport=tls SIP/2.0',
        f'Via: SIP/2.0/TCP 127.0.0.2:{unauthorized_port};branch=z9hG4bKunauthorized;rport',
        'From: <sip:unauthorized@localhost>;tag=unauthorized',
        'To: <sip:fax@localhost>', 'Call-ID: unauthorized-regression',
        'CSeq: 1 INVITE', 'Max-Forwards: 70', 'Content-Length: 0', '', '',
    ])).encode())
    rejected, _ = SipStream(unauthorized).read()
    assert rejected.startswith('SIP/2.0 403'), rejected
    unauthorized.close()
    caller_port = caller.getsockname()[1]
    call_id = 'avoip-reply-regression-' + uuid.uuid4().hex
    body = 'v=0\r\no=fixture 1 1 IN IP4 192.0.2.10\r\ns=fixture\r\nc=IN IP4 192.0.2.10\r\nt=0 0\r\nm=audio 18000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n'
    headers = [
        'INVITE sips:fax@127.0.0.1:5061;transport=tls SIP/2.0',
        f'Via: SIP/2.0/TCP 127.0.0.1:{caller_port};branch=z9hG4bK{call_id};rport',
        'From: <sip:fixture@localhost>;tag=fixture-from',
        'To: <sip:fax@localhost>', f'Call-ID: {call_id}', 'CSeq: 1 INVITE',
        f'Contact: <sip:fixture@127.0.0.1:{caller_port};transport=tcp>',
        'Max-Forwards: 70', 'Content-Type: application/sdp',
        f'Content-Length: {len(body)}', '', body,
    ]
    caller.sendall('\r\n'.join(headers).encode())
    downstream, _ = backend.accept()
    downstream_stream = SipStream(downstream)
    request_headers, _ = downstream_stream.read()
    internal_rr = [route.strip() for route in re.findall(r'(?im)^Record-Route:\s*(.+)$', request_headers)]
    assert len(internal_rr) == 2, f'FreeSWITCH leg lost its two-sided route set: {internal_rr}'
    assert any('.svc.' in value for value in internal_rr), 'Private Service route missing on FreeSWITCH leg'
    assert any(f'sip:{PUBLIC_HOST}:15061;transport=tcp' in value for value in internal_rr), \
        f'Fixture public route missing: {internal_rr}'
    response_headers = ['SIP/2.0 200 OK']
    for line in request_headers.split('\r\n')[1:]:
        if line.lower().startswith(('via:', 'from:', 'to:', 'call-id:', 'cseq:', 'record-route:')):
            response_headers.append(line + (';tag=fixture-to' if line.lower().startswith('to:') else ''))
    private_body = body.replace('192.0.2.10', '172.20.50.82').replace('18000', '11000')
    response_headers += ['Contact: <sip:fax@127.0.0.3:16061;transport=tls>',
                         'Content-Type: application/sdp', f'Content-Length: {len(private_body)}']
    response = ('\r\n'.join(response_headers) + '\r\n\r\n' + private_body).encode()
    upstream = SipStream(caller)
    for status in ('180 Ringing', '183 Session Progress'):
        provisional = response_headers.copy()
        provisional[0] = f'SIP/2.0 {status}'
        provisional[-2:] = ['Content-Length: 0']
        if status.startswith('183'):
            provisional = [line.replace('Contact: <sip:fax@127.0.0.3:16061;transport=tls>',
                                        'Contact: <sip:fax@127.0.0.3:16061;transport=tls;endpoint=keep>;expires=42')
                           for line in provisional]
            provisional.insert(-1, 'Record-Route: <sips:proxy.example.test:5061;transport=tls;lr;r2=on>')
        downstream.sendall(('\r\n'.join(provisional) + '\r\n\r\n').encode())
        for _ in range(10):
            forwarded, _ = upstream.read()
            if forwarded.startswith(f'SIP/2.0 {status}'):
                break
        assert forwarded.startswith(f'SIP/2.0 {status}'), forwarded
        if status.startswith('183'):
            assert f'Contact: <sips:fax@{PUBLIC_HOST}:5061;transport=tls;endpoint=keep>;expires=42' in forwarded
            assert 'Record-Route: <sips:proxy.example.test:5061;transport=tls;lr;r2=on>' in forwarded
        else:
            assert f'Contact: <sips:fax@{PUBLIC_HOST}:5061;transport=tls>' in forwarded, forwarded
        assert '.svc.' not in forwarded and '66.165.222.101' not in forwarded, forwarded
        assert f'sn=public_tls;r2=on' not in forwarded, forwarded
    outputs = []
    for delay in (0, 0.2, 2, 4):
        time.sleep(delay)
        downstream.sendall(response)
        response_headers, received = upstream.final()
        contact = re.search(r'(?im)^Contact:\s*<([^>]+)>', response_headers)
        assert contact, 'Contact missing from a forwarded 200 OK'
        assert re.fullmatch(rf'sips:[^@]+@{re.escape(PUBLIC_HOST)}:5061;transport=tls', contact[1]), \
            f'Public Contact is not the canonical TLS identity: {contact[1]}'
        public_rr = [route.strip() for route in re.findall(r'(?im)^Record-Route:\s*(.+)$', response_headers)]
        assert len(public_rr) == 1, f'Carrier response must contain only the public Record-Route: {public_rr}'
        assert f'sip:{PUBLIC_HOST}:15061;transport=tcp' in public_rr[0], \
            f'Fixture public Record-Route missing: {public_rr}'
        assert '.svc.' not in '\n'.join(public_rr), f'Private Service Record-Route leaked to caller: {public_rr}'
        assert 'r2=on' not in '\n'.join(public_rr), f'Orphan paired-route marker leaked: {public_rr}'
        assert '.svc.' not in response_headers and '66.165.222.101' not in response_headers, \
            f'Private or unintended signaling address leaked: {response_headers}'
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

    # A carrier-side 2xx ACK carries only the public Route URI. It must pass
    # through loose_route and be sent to the private FreeSWITCH backend.
    call_id_ack = ('\r\n'.join([
        f'ACK sips:fax@{PUBLIC_HOST}:5061;transport=tls SIP/2.0',
        f'Via: SIP/2.0/TCP 127.0.0.1:{caller_port};branch=z9hG4bK{call_id}-ack;rport',
        'From: <sip:fixture@localhost>;tag=fixture-from',
        'To: <sip:fax@localhost>;tag=fixture-to',
        f'Call-ID: {call_id}', 'CSeq: 1 ACK', f'Route: {public_rr[0]}',
        'Max-Forwards: 70', 'Content-Length: 0', '', '',
    ])).encode()
    caller.sendall(call_id_ack)
    ack_headers, _ = downstream_stream.read(timeout=5)
    assert ack_headers.startswith('ACK '), f'2xx ACK did not reach FreeSWITCH: {ack_headers}'
    assert f'Call-ID: {call_id}' in ack_headers
    assert 'tag=fixture-from' in ack_headers and 'tag=fixture-to' in ack_headers
    caller.sendall(call_id_ack)
    duplicate_ack, _ = downstream_stream.read(timeout=5)
    assert duplicate_ack.startswith('ACK '), duplicate_ack

    missing_route_ack = re.sub(br'(?im)^Route: [^\r\n]+\r\n', b'', call_id_ack)
    missing_route_ack = missing_route_ack.replace(f'branch=z9hG4bK{call_id}-ack'.encode(),
                                                  f'branch=z9hG4bK{call_id}-missing-route'.encode())
    assert b'Route:' not in missing_route_ack
    caller.sendall(missing_route_ack)
    try:
        downstream_stream.read(timeout=0.5)
    except socket.timeout:
        pass
    else:
        raise AssertionError('ACK without a dialog Route reached FreeSWITCH')

    def dialog_request(method, cseq, route, ruri, branch):
        return ('\r\n'.join([
            f'{method} {ruri} SIP/2.0',
            f'Via: SIP/2.0/TCP 127.0.0.1:{caller_port};branch=z9hG4bK{call_id}-{branch};rport',
            'From: <sip:fixture@localhost>;tag=fixture-from',
            'To: <sip:fax@localhost>;tag=fixture-to',
            f'Call-ID: {call_id}', f'CSeq: {cseq} {method}',
            f'Route: {route}', 'Max-Forwards: 70', 'Content-Length: 0', '', '',
        ])).encode()

    # A later request on the same dialog must still use the backend; its
    # response and ACK must keep the public Contact and the private next hop.
    caller.sendall(dialog_request('INVITE', 2, public_rr[0],
                                  f'sips:fax@{PUBLIC_HOST}:5061;transport=tls', 'reinvite'))
    reinvite, _ = downstream_stream.read()
    assert reinvite.startswith('INVITE '), reinvite
    assert f'Call-ID: {call_id}' in reinvite
    reinvite_reply = ['SIP/2.0 200 OK']
    for line in reinvite.split('\r\n')[1:]:
        if line.lower().startswith(('via:', 'from:', 'to:', 'call-id:', 'cseq:')):
            reinvite_reply.append(line)
    reinvite_reply += ['Contact: <sip:fax@127.0.0.3:16061;transport=tls>',
                       'Content-Length: 0', '', '']
    downstream.sendall('\r\n'.join(reinvite_reply).encode())
    reinvite_answer, _ = upstream.final()
    assert reinvite_answer.startswith('SIP/2.0 200 OK'), reinvite_answer
    assert f'Contact: <sips:fax@{PUBLIC_HOST}:5061;transport=tls>' in reinvite_answer
    caller.sendall(dialog_request('ACK', 2, public_rr[0],
                                  f'sips:fax@{PUBLIC_HOST}:5061;transport=tls', 'reinvite-ack'))
    reinvite_ack, _ = downstream_stream.read()
    assert reinvite_ack.startswith('ACK '), reinvite_ack

    caller.sendall(dialog_request('BYE', 3, public_rr[0],
                                  f'sips:fax@{PUBLIC_HOST}:5061;transport=tls', 'caller-bye'))
    carrier_bye, _ = downstream_stream.read()
    assert carrier_bye.startswith('BYE '), carrier_bye

    # FreeSWITCH retained both routes and can send its own in-dialog BYE to
    # the original caller Contact without looping into the backend service.
    # A UAS reverses the Record-Route set when constructing its Route set.
    backend_bye = dialog_request('BYE', 4, internal_rr[1] + '\r\nRoute: ' + internal_rr[0],
                                 f'sip:fixture@127.0.0.1:{caller_port};transport=tcp', 'backend-bye')
    backend_caller = socket.socket()
    backend_caller.bind(('127.0.0.3', 0))
    backend_caller.connect(('127.0.0.1', 15062))
    backend_caller.sendall(backend_bye)
    outbound_bye, _ = upstream.read()
    assert outbound_bye.startswith('BYE '), outbound_bye

    def initial_request(test_id, method, branch):
        return ('\r\n'.join([
            f'{method} sips:fax@{PUBLIC_HOST}:5061;transport=tls SIP/2.0',
            f'Via: SIP/2.0/TCP 127.0.0.1:{caller_port};branch={branch};rport',
            'From: <sip:fixture@localhost>;tag=fixture-from',
            'To: <sip:fax@localhost>', f'Call-ID: {test_id}',
            f'CSeq: 1 {method}',
            f'Contact: <sip:fixture@127.0.0.1:{caller_port};transport=tcp>',
            'Max-Forwards: 70', 'Content-Length: 0', '', '',
        ])).encode()

    def backend_final(request, status, tag):
        lines = [f'SIP/2.0 {status}']
        for line in request.split('\r\n')[1:]:
            if line.lower().startswith(('via:', 'from:', 'to:', 'call-id:', 'cseq:', 'record-route:')):
                lines.append(line + (f';tag={tag}' if line.lower().startswith('to:') else ''))
        lines += ['Content-Length: 0', '', '']
        downstream.sendall('\r\n'.join(lines).encode())

    def until_status(status):
        for _ in range(10):
            header, _ = upstream.read()
            if header.startswith(f'SIP/2.0 {status}'):
                return header
        raise AssertionError(f'No {status} response arrived')

    negative_id = 'avoip-negative-' + uuid.uuid4().hex
    negative_branch = 'z9hG4bK' + negative_id
    caller.sendall(initial_request(negative_id, 'INVITE', negative_branch))
    negative_invite, _ = downstream_stream.read()
    backend_final(negative_invite, '486 Busy Here', 'negative-to')
    negative_response = until_status('486')
    assert '.svc.' not in negative_response and 'r2=on' not in negative_response
    negative_ack = initial_request(negative_id, 'ACK', negative_branch).decode()
    negative_ack = negative_ack.replace('To: <sip:fax@localhost>',
                                        'To: <sip:fax@localhost>;tag=negative-to')
    caller.sendall(negative_ack.encode())
    relayed_negative_ack, _ = downstream_stream.read()
    assert relayed_negative_ack.startswith('ACK '), relayed_negative_ack

    cancel_id = 'avoip-cancel-' + uuid.uuid4().hex
    cancel_branch = 'z9hG4bK' + cancel_id
    caller.sendall(initial_request(cancel_id, 'INVITE', cancel_branch))
    pending_invite, _ = downstream_stream.read()
    caller.sendall(initial_request(cancel_id, 'CANCEL', cancel_branch))
    relayed_cancel, _ = downstream_stream.read()
    assert relayed_cancel.startswith('CANCEL '), relayed_cancel
    backend_final(pending_invite, '487 Request Terminated', 'cancelled-to')
    assert until_status('487').startswith('SIP/2.0 487')

    fail_answers.set()
    downstream.sendall(response)
    try:
        upstream.read(timeout=2)
    except socket.timeout:
        pass
    else:
        raise AssertionError('Final SDP response escaped after RTPEngine failure')
    print(json.dumps({'forwarded_200': len(outputs), 'identical_bodies': True,
                      'carrier_record_routes': 1, 'private_route_retained_for_backend': True,
                      'carrier_ack_reached_backend': True,
                      'connection': PUBLIC, 'audio_port': PUBLIC_PORT,
                      'failed_rewrite_dropped': True, 'ng_answers': commands.count('answer')}))


def fixture_config(source):
    cfg = source
    cfg = re.sub(r'^\s*loadmodule "(?:tls|siptrace)\.so".*\n', '', cfg, flags=re.M)
    cfg = re.sub(r'^\s*modparam\("(?:tls|siptrace)".*\n', '', cfg, flags=re.M)
    cfg = re.sub(r'^enable_tls=.*$', 'enable_tls=0', cfg, flags=re.M)
    cfg = cfg.replace('tcp_accept_haproxy=yes', 'tcp_accept_haproxy=no')
    cfg = re.sub(r'^listen=(?:tcp|tls):.* name "public_(?:tcp|tls)"$',
                 'listen=tcp:127.0.0.1:15061 name "public_tls"', cfg, flags=re.M)
    cfg = re.sub(r'^listen=tls:.* name "private_tls"$',
                 'listen=tcp:127.0.0.1:15062 name "private_tls"', cfg, flags=re.M)
    # Make the paired Route URIs local to the isolated TCP fixture. The chart
    # render separately verifies the production SIPS/TLS identities.
    cfg = cfg.replace('modparam("rr", "sockname_mode", 1)',
                      'modparam("rr", "sockname_mode", 1)\nmodparam("rr", "ignore_sips", 1)')
    cfg = cfg.replace(':5062;transport=tls;sn=private_tls', ':15062;transport=tcp;sn=private_tls')
    cfg = cfg.replace(':5061;transport=tls;sn=public_tls', ':15061;transport=tcp;sn=public_tls')
    cfg = cfg.replace('$(route_uri{uri.port}) != "5062"', '$(route_uri{uri.port}) != "15062"')
    cfg = cfg.replace('$(route_uri{uri.port}) != "5061"', '$(route_uri{uri.port}) != "15061"')
    cfg = cfg.replace('$(route_uri{uri.transport}) != "tls"', '$(route_uri{uri.transport}) != "tcp"')
    cfg = re.sub(r'^(alias="[^"]+):5061"$', r'\1:15061"', cfg, flags=re.M)
    cfg = re.sub(r'^(alias="[^"]+):5062"$', r'\1:15062"', cfg, flags=re.M)
    cfg = re.sub(r'modparam\("rtpengine", "rtpengine_sock", "[^"]+"\)',
                 'modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:12223")', cfg)
    cfg = re.sub(r'\$du = "sip:[^"]+";', '$du = "sip:127.0.0.3:16061;transport=tcp";', cfg)
    cfg = cfg.replace('34.210.91.112/28', '127.0.0.1')
    cfg = cfg.replace('172.16.0.0/12', '127.0.0.3')
    cfg = cfg.replace('$proto == "tls" && $Rp == 5061', '$proto == "tcp" && $Rp == 15061')
    cfg = cfg.replace('$proto == "tls" && $Rp == 5062', '$proto == "tcp" && $Rp == 15062')
    return cfg


def runner(args):
    base = ['kubectl', '--context', args.context, '-n', args.namespace, 'exec', '-i',
            'deploy/' + args.deployment]
    stem = '/tmp/avoip-replies-' + uuid.uuid4().hex
    cfg = fixture_config(pathlib.Path(args.config).read_text())
    assert 'SIP wire request' in cfg, 'Render with kamailio.sipLogging.diagnostics.enabled=true'
    subprocess.run(base + ['-c', 'kamailio', '--', 'sh', '-c', f'cat > {stem}.cfg'],
                   input=cfg, text=True, check=True)
    subprocess.run(base + ['-c', 'kamailio', '--', 'kamailio', '-c', '-f', stem + '.cfg'], check=True)
    fixture = subprocess.Popen(base + ['-c', 'netshoot', '--', 'python3', '-', '--harness',
                                       '--public-host', args.public_host],
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
    assert re.search(r'SIP ack send .*socket=\d+:127\.0\.0\.1:15062 .*socket_name=private_tls', log), \
        'Serialized backend ACK did not use private_tls'
    assert re.search(r'SIP wire request .*method=INVITE .*socket=\d+:127\.0\.0\.1:15062 .*socket_name=private_tls', log), \
        'Serialized initial INVITE did not use private_tls'
    assert re.search(r'SIP wire request .*method=BYE .*socket=\d+:127\.0\.0\.1:15061 .*socket_name=public_tls', log), \
        'Serialized backend BYE did not use public_tls'
    print('Serialized private/public SIP socket checks passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harness', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--config')
    parser.add_argument('--context')
    parser.add_argument('--namespace', default='core-prod')
    parser.add_argument('--deployment')
    parser.add_argument('--public-host', default=PUBLIC_HOST,
                        help='site-specific public SIP dialog hostname')
    options = parser.parse_args()
    PUBLIC_HOST = options.public_host
    if options.harness:
        harness()
    else:
        if not all((options.config, options.context, options.deployment)):
            parser.error('--config, --context and --deployment are required')
        runner(options)
