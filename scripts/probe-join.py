#!/usr/bin/env python3
"""Read-only join-service probe; never reveals a client identity or requests group credentials."""
import argparse
import base64
import json
import os
import socket
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('host', help='Coordinator IP or hostname')
parser.add_argument('--port', type=int, default=45732)
args = parser.parse_args()
session = str(uuid.uuid4()).upper()
request = {'version': 1, 'kind': 'commit', 'session': session,
           'blob': base64.b64encode(os.urandom(32)).decode('ascii')}
try:
    with socket.create_connection((args.host, args.port), timeout=3) as connection:
        connection.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
        frame = bytearray()
        while b'\n' not in frame:
            chunk = connection.recv(1024)
            if not chunk:
                raise ValueError('Host closed before returning a join challenge')
            frame.extend(chunk)
            if len(frame) > 8192:
                raise ValueError('Oversized response')
        reply = json.loads(frame.split(b'\n', 1)[0])
        assert reply['version'] == 1 and reply['kind'] == 'challenge' and reply['session'] == session
        assert len(base64.b64decode(reply['hello']['publicKey'], validate=True)) == 32
    print('PASS: coordinator TCP port and join challenge respond; no membership or group key requested.')
except (OSError, ValueError, KeyError, AssertionError) as error:
    parser.exit(1, f'FAIL: join service did not respond correctly ({error})\n')
