#!/usr/bin/env python3
"""Negative SIP probes for an isolated AVoIP deployment. No real credentials used."""

import argparse
import hashlib
import re
import secrets
import socket
import ssl
import sys


def digest(value):
    return hashlib.md5(value.encode('utf-8')).hexdigest()


def request(method, target, host, call_id, cseq, transport, auth=''):
    local = 'security-probe.invalid'
    branch = 'z9hG4bK' + secrets.token_hex(8)
    headers = [
        f'{method} sip:{target}@{host} SIP/2.0',
        f'Via: SIP/2.0/{transport.upper()} 127.0.0.1:5060;branch={branch};rport',
        'Max-Forwards: 70',
        f'From: <sip:probe@{local}>;tag={call_id}',
        f'To: <sip:{target}@{host}>',
        f'Call-ID: {call_id}@{local}',
        f'CSeq: {cseq} {method}',
        f'Contact: <sip:probe@{local}>',
    ]
    if auth:
        headers.append(auth)
    body = ''
    if method == 'INVITE':
        body = ('v=0\r\no=probe 1 1 IN IP4 127.0.0.1\r\ns=AVoIP security probe\r\n'
                'c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 9 RTP/AVP 0\r\n'
                'a=rtpmap:0 PCMU/8000\r\n')
        headers.append('Content-Type: application/sdp')
    headers.append(f'Content-Length: {len(body)}')
    return ('\r\n'.join(headers) + '\r\n\r\n' + body).encode('ascii')


def responses(data):
    while b'\r\n\r\n' in data:
        head, data = data.split(b'\r\n\r\n', 1)
        match = re.search(rb'(?im)^Content-Length:\s*(\d+)\s*$', head)
        length = int(match.group(1)) if match else 0
        if len(data) < length:
            return None, head + b'\r\n\r\n' + data
        data = data[length:]
        status = re.match(rb'SIP/2\.0\s+(\d{3})\b', head)
        if status and int(status.group(1)) >= 200:
            return (int(status.group(1)), head.decode('utf-8', 'replace')), data
    return None, data


def exchange(args, payload):
    family, kind, proto, _, address = socket.getaddrinfo(
        args.host, args.port, type=socket.SOCK_DGRAM if args.transport == 'udp' else socket.SOCK_STREAM
    )[0]
    with socket.socket(family, kind, proto) as raw:
        raw.settimeout(args.timeout)
        if args.bind:
            raw.bind((args.bind, 0))
        if args.transport == 'udp':
            raw.sendto(payload, address)
            while True:
                result, _ = responses(raw.recv(65535))
                if result:
                    return result
        raw.connect(address)
        if args.transport == 'tcp':
            return stream_exchange(raw, payload)
        context = ssl.create_default_context(cafile=args.ca)
        with context.wrap_socket(raw, server_hostname=args.sni or args.host) as connection:
            return stream_exchange(connection, payload)


def stream_exchange(connection, payload):
    connection.sendall(payload)
    pending = b''
    while True:
        chunk = connection.recv(65535)
        if not chunk:
            raise ConnectionError('peer closed before a final SIP response')
        pending += chunk
        result, pending = responses(pending)
        if result:
            return result


def bad_digest(challenge, target, host, method):
    header = re.search(r'(?im)^(WWW-Authenticate|Proxy-Authenticate):\s*Digest\s+([^\r\n]+)', challenge)
    if not header:
        raise AssertionError('authentication challenge has no Digest header')
    fields = dict(re.findall(r'(\w+)="([^"]*)"', header.group(2)))
    realm, nonce = fields['realm'], fields['nonce']
    uri = f'sip:{target}@{host}'
    username, password = 'invalid-probe', 'deliberately-wrong-credential'
    ha1 = digest(f'{username}:{realm}:{password}')
    ha2 = digest(f'{method}:{uri}')
    qop = 'auth' if 'auth' in fields.get('qop', '').split(',') else ''
    extra = ''
    if qop:
        nc, cnonce = '00000001', secrets.token_hex(8)
        response = digest(f'{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}')
        extra = f', qop={qop}, nc={nc}, cnonce="{cnonce}"'
    else:
        response = digest(f'{ha1}:{nonce}:{ha2}')
    name = 'Proxy-Authorization' if header.group(1).lower().startswith('proxy') else 'Authorization'
    return (f'{name}: Digest username="{username}", realm="{realm}", '
            f'nonce="{nonce}", uri="{uri}", response="{response}"{extra}')


def check(args, method, target, expected, credential=None):
    call_id = secrets.token_hex(8)
    status, headers = exchange(args, request(method, target, args.domain, call_id, 1,
                                             args.transport))
    print(f'{args.mode}: {method} {target} call-id={call_id}@security-probe.invalid '
          f'without credentials -> {status}')
    if status not in expected:
        raise AssertionError(f'expected {sorted(expected)}, got {status}')
    if credential == 'invalid':
        auth = bad_digest(headers, target, args.domain, method)
        status, _ = exchange(args, request(method, target, args.domain, call_id, 2,
                                           args.transport, auth))
        print(f'{args.mode}: {method} {target} call-id={call_id}@security-probe.invalid '
              f'with invalid credentials -> {status}')
        if status not in {401, 403, 407}:
            raise AssertionError(f'invalid credential was not rejected: {status}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('edge-denied', 'edge-allowed', 'private-auth', 'asterisk-auth'))
    parser.add_argument('--host', required=True, help='non-production SIP listener IP or DNS name')
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--domain', required=True, help='SIP request URI host')
    parser.add_argument('--did', required=True, help='test DID; never use a billable destination')
    parser.add_argument('--outbound-number', required=True, help='unassigned, non-routable test number')
    parser.add_argument('--transport', choices=('udp', 'tcp', 'tls'), required=True)
    parser.add_argument('--sni', help='TLS certificate hostname when connecting to an IP')
    parser.add_argument('--ca', help='test deployment TLS CA bundle')
    parser.add_argument('--bind', help='source IP on the runner')
    parser.add_argument('--timeout', type=float, default=5)
    args = parser.parse_args()
    if args.mode in ('private-auth', 'asterisk-auth') and args.transport != 'tls':
        parser.error('private authentication probes require TLS')
    if args.mode == 'edge-denied':
        for method, target in [('OPTIONS', 'nm'), ('REGISTER', 'probe'),
                               ('INVITE', args.did), ('INVITE', args.outbound_number),
                               ('MESSAGE', args.did)]:
            check(args, method, target, {403})
        call_id = secrets.token_hex(8)
        status, _ = exchange(args, request(
            'INVITE', args.outbound_number, args.domain, call_id, 1,
            args.transport, 'Authorization: Digest username="invalid-probe", response="bad"'))
        print(f'edge-denied: outbound INVITE call-id={call_id}@security-probe.invalid '
              f'with invalid credentials -> {status}')
        if status != 403:
            raise AssertionError(f'invalid credentials bypassed source ACL: {status}')
    elif args.mode == 'edge-allowed':
        check(args, 'REGISTER', 'probe', {403})
        for auth in ('none', 'invalid-header'):
            call_id = secrets.token_hex(8)
            bogus = '' if auth == 'none' else 'Authorization: Digest username="invalid-probe", response="bad"'
            status, _ = exchange(args, request('INVITE', args.outbound_number,
                                               args.domain, call_id, 1,
                                               args.transport, bogus))
            print(f'edge-allowed: outbound INVITE call-id={call_id}@security-probe.invalid '
                  f'with {auth} -> {status}')
            if not 400 <= status <= 699:
                raise AssertionError(f'outbound call was not rejected: {status}')
    else:
        check(args, 'INVITE', args.did, {401, 407}, credential='invalid')
        check(args, 'INVITE', args.outbound_number, {401, 407}, credential='invalid')
    print('PASS: all negative probes were rejected')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, ssl.SSLError, KeyError, ValueError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
