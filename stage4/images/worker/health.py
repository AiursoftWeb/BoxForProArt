#!/usr/bin/env python3
"""Probe the local daemon; waiting for first approval is a valid startup state."""
import json
import os
from pathlib import Path
import urllib.request

if (Path(os.environ.get('WORKER_RUNTIME_DIR', '/tmp/worker')) / 'pairing').exists():
    raise SystemExit(0)

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for path in (Path.home() / '.happier/servers').glob('*/daemon.state.json'):
    try:
        state = json.loads(path.read_text())
        request = urllib.request.Request(
            f"http://127.0.0.1:{int(state['httpPort'])}/ping", data=b'{}',
            headers={'Content-Type': 'application/json',
                     'x-happier-daemon-token': state['controlToken']})
        with opener.open(request, timeout=3) as response:
            if response.status == 200:
                raise SystemExit(0)
    except (OSError, ValueError, KeyError):
        continue
raise SystemExit(1)
