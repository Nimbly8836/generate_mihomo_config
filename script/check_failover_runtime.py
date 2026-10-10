#!/usr/bin/env python3
"""Isolated Mihomo failover regression; loopback fixtures only, no real subscriptions."""
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
from typing import Any, cast

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('MIHOMO_BIN') or shutil.which('mihomo')


class ProbeServer(http.server.ThreadingHTTPServer):
    def __init__(self, label: str):
        self.offline, self.probe_status, self.hits, self.label = False, 204, 0, label
        super().__init__(('127.0.0.1', 0), Probe)


class Probe(http.server.BaseHTTPRequestHandler):
    @property
    def probe(self) -> ProbeServer:
        return cast(ProbeServer, self.server)

    def do_CONNECT(self):
        if self.probe.offline:
            self.close_connection = True
            return
        self.send_response(200)
        self.end_headers()
        self.close_connection = False
        self.handle_one_request()

    def do_HEAD(self):
        if self.probe.offline:
            self.close_connection = True
            return
        self.send_response(self.probe.probe_status)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.probe.offline:
            self.close_connection = True
            return
        self.probe.hits += 1
        body = self.probe.label.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any):
        pass


def fixture(label):
    server = ProbeServer(label)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def until(check, label, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, ValueError, http.client.HTTPException):
            pass
        time.sleep(.15)
    raise AssertionError('runtime condition failed: ' + label)


def scenario(binary: str, subscription_backup: bool):
    airport1, airport2, own, direct = [fixture(name) for name in ['airport1', 'airport2', 'self-hosted', 'DIRECT-LEAK']]
    servers = [airport1, airport2, own, direct]
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix='mihomo-failover-') as raw_directory:
            directory = Path(raw_directory)
            files = []
            providers = []
            for index, server in enumerate(servers[:3]):
                file = directory / f'provider-{index}.json'
                file.write_text(json.dumps({'proxies': [{'name': server.label, 'type': 'http', 'server': '127.0.0.1', 'port': server.server_port}]}))
                files.append(file)
                if index < 2 or subscription_backup:
                    providers.append({'name': 'airport' if index < 2 else 'self', 'type': 'file', 'path': str(file), 'url': 'https://example.invalid/unused'})
            settings = {'primary': ['airport'], 'url': 'http://probe.invalid/health', 'interval': 1, 'timeout': 500}
            settings.update({'backup': ['self']} if subscription_backup else {'backup_nodes': ['self-hosted']})
            values = {'web_secret': 'fixture-only', 'proxy_providers': providers, 'failover': settings,
                      'local_proxies': [] if subscription_backup else [{'name': 'self-hosted', 'type': 'http', 'server': '127.0.0.1', 'port': own.server_port}]}
            source, output = directory / 'values.json', directory / 'generated.yaml'
            source.write_text(json.dumps(values))
            generated = subprocess.run(['ruby', 'generate_mihomo_config.rb', '-v', str(source), '-o', str(output)], cwd=ROOT, capture_output=True, text=True, timeout=15)
            if generated.returncode:
                raise AssertionError('fixture generation failed: ' + generated.stderr)
            config = json.loads(subprocess.check_output(['ruby', '-rpsych', '-rjson', '-e', 'puts JSON.generate(Psych.safe_load_file(ARGV[0], aliases: true))', str(output)], timeout=10))
            controller, mixed = free_port(), free_port()
            # Keep generated groups/providers intact; omit unrelated ruleset downloads, DNS and TUN.
            isolated = {key: config[key] for key in ['proxies', 'proxy-providers', 'proxy-groups']}
            isolated.update({'external-controller': f'127.0.0.1:{controller}', 'mixed-port': mixed, 'bind-address': '127.0.0.1',
                             'mode': 'rule', 'rules': ['MATCH,failover'], 'profile': {'store-selected': False}})
            runtime = directory / 'runtime.json'
            runtime.write_text(json.dumps(isolated, ensure_ascii=False))
            with (directory / 'core.log').open('w') as log:
                process = subprocess.Popen([binary, '-d', str(directory), '-f', str(runtime)], stdout=log, stderr=log)

                def api(path, method='GET') -> Any:
                    request = urllib.request.Request(f'http://127.0.0.1:{controller}{path}', method=method)
                    with urllib.request.urlopen(request, timeout=2) as response:
                        body = response.read()
                        return json.loads(body) if body else None

                def now(group):
                    return api('/proxies/' + group)['now']

                def traffic():
                    connection = http.client.HTTPConnection('127.0.0.1', mixed, timeout=2)
                    try:
                        # Explicit HTTP proxy request avoids environment NO_PROXY bypasses.
                        connection.request('GET', f'http://127.0.0.1:{direct.server_port}/payload')
                        response = connection.getresponse()
                        body = response.read().decode()
                        return body if response.status == 200 else None
                    finally:
                        connection.close()

                try:
                    until(lambda: now('failover') == 'failover_primary' and traffic() == 'airport1', 'airport first')
                except AssertionError:
                    print((directory / 'core.log').read_text()[-6000:])
                    raise
                # A low-latency response with the wrong HTTP status must NOT count as healthy.
                airport1.probe_status = 200
                until(lambda: now('failover_primary') == 'airport | airport2' and traffic() == 'airport2', 'reject HTTP 200 when 204 is expected')
                airport1.offline = airport2.offline = True
                until(lambda: now('failover') == 'failover_backup' and traffic() == 'self-hosted', 'airport outage -> self-hosted')
                airport2.offline = False
                until(lambda: now('failover') == 'failover_primary' and traffic() == 'airport2', 'automatic return to recovered airport')
                # A provider containing only direct placeholders leaves no eligible nodes.
                for file in files[:2]:
                    file.write_text('{"proxies": [{"name": "filtered-direct", "type": "direct"}]}')
                for provider in ['airport', 'airport__2']:
                    api('/providers/proxies/' + provider, 'PUT')
                until(lambda: now('failover_primary') == 'REJECT' and now('failover') == 'failover_backup' and traffic() == 'self-hosted', 'empty airport lists -> self-hosted')
                own.offline = True
                until(lambda: not api('/proxies/failover_backup')['extra']['http://probe.invalid/health']['alive'], 'backup failure observed')
                try:
                    assert traffic() is None, 'all-down traffic unexpectedly succeeded'
                except (OSError, http.client.HTTPException):
                    pass
                assert direct.hits == 0, 'traffic leaked to DIRECT'
                # Initial empty providers are a separate case: failed refreshes normally
                # retain usable cached nodes instead of replacing them with empty lists.
                process.terminate()
                process.wait(timeout=5)
                for file in files[:2]:
                    file.write_text('{"proxies": []}')
                own.offline = False
                process = subprocess.Popen([binary, '-d', str(directory), '-f', str(runtime)], stdout=log, stderr=log)
                until(lambda: now('failover_primary') == 'REJECT' and now('failover') == 'failover_backup' and traffic() == 'self-hosted', 'boot with empty airport providers')
                assert direct.hits == 0, 'empty providers leaked to DIRECT'
                kind = 'subscription backup' if subscription_backup else 'local node backup'
                print('PASS:', kind, '- priority, strict status, outage/recovery, empty providers, all-down without DIRECT')
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    if not BINARY:
        raise SystemExit('Install Mihomo or set MIHOMO_BIN to its executable path.')
    scenario(BINARY, False)
    scenario(BINARY, True)
