#!/usr/bin/env python3
"""Optional localhost-only Mihomo check of generated selective AI IPv4 DNS.

Requires ruby and mihomo (or MIHOMO_BIN). Does not load private configs,
subscriptions or remote providers, and never enables TUN or changes host routes.
"""
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
BINARY = os.environ.get('MIHOMO_BIN', 'mihomo')
PROVIDERS = ['openai_domain', 'claude_domain', 'gemini_domain', 'copilot_domain', 'ai_domain']
DOMAINS = [f'ai-{i}.runtime.example.org' for i in range(len(PROVIDERS))]


def question(data):
    pos = 12
    while data[pos]:
        pos += data[pos] + 1
    pos += 1
    return struct.unpack('!H', data[pos:pos + 2])[0], pos + 4


def serve_dns(sock, stopped):
    ipv4 = socket.inet_pton(socket.AF_INET, '192.0.2.7')
    ipv6 = socket.inet_pton(socket.AF_INET6, '2001:db8::7')
    # HTTPS service record with an IPv6 hint, exercising disable-qtype-65.
    https = b'\x00\x01\x00' + struct.pack('!HH', 6, len(ipv6)) + ipv6
    while not stopped.is_set():
        try:
            data, peer = sock.recvfrom(4096)
        except TimeoutError:
            continue
        except OSError:
            return
        qtype, end = question(data)
        payload = {1: ipv4, 28: ipv6, 65: https}.get(qtype)
        answer = b''
        if payload:
            answer = b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 60, len(payload)) + payload
        response = data[:2] + struct.pack('!HHHHH', 0x8180, 1, int(bool(payload)), 0, 0) + data[12:end] + answer
        sock.sendto(response, peer)


def query(port, domain, qtype):
    name = b''.join(bytes([len(part)]) + part.encode() for part in domain.split('.')) + b'\0'
    packet = struct.pack('!HHHHHH', 1234, 0x100, 1, 0, 0, 0) + name + struct.pack('!HH', qtype, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.5)
        sock.sendto(packet, ('127.0.0.1', port))
        response = sock.recv(4096)
    _, flags, _, answers, _, _ = struct.unpack('!HHHHHH', response[:12])
    assert flags & 15 == 0, f'{domain} qtype={qtype}: DNS rcode={flags & 15}'
    return answers


def run_case(directory, upstream, enabled, mode):
    directory.mkdir()
    values = {'web_secret': 'local-test-only', 'ai_ipv4_only': enabled, 'fake_ip_filter_mode': mode,
              'config_overrides': {'ipv6': True, 'dns': {'ipv6': True}}}
    source, generated = directory / 'values.json', directory / 'generated.yaml'
    source.write_text(json.dumps(values))
    subprocess.run(['ruby', str(ROOT / 'generate_mihomo_config.rb'), '-v', str(source),
                    '-t', str(ROOT / 'config-template.yaml.erb'), '-o', str(generated)],
                   check=True, capture_output=True, timeout=20)
    try:
        config = json.loads(subprocess.check_output(['ruby', '-rpsych', '-rjson', '-e',
            'puts JSON.generate(Psych.safe_load_file(ARGV[0], aliases: true))', str(generated)], timeout=10))
    except (json.JSONDecodeError, subprocess.SubprocessError) as error:
        raise AssertionError('Could not decode the locally generated test configuration') from error
    dns = config['dns']
    # Replace transport endpoints only; retain generated policy filters and IPv6 pools.
    for key in ['nameserver', 'direct-nameserver', 'default-nameserver']:
        dns[key] = [upstream]
    for key, servers in dns.get('nameserver-policy', {}).items():
        dns['nameserver-policy'][key] = [upstream + '#' + address.partition('#')[2] for address in servers]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(('127.0.0.1', 0))
        controller = sock.getsockname()[1]
    dns.update({'listen': f'127.0.0.1:{port}', 'use-hosts': False, 'use-system-hosts': False})
    providers = {}
    for name, domain in zip(PROVIDERS, DOMAINS, strict=True):
        path = directory / f'{name}.yaml'
        path.write_text(f'payload:\n  - {domain}\n')
        providers[name] = {'type': 'file', 'behavior': 'domain', 'format': 'yaml', 'path': str(path)}
    runtime = {'mixed-port': 0, 'ipv6': True, 'dns': dns, 'tun': {'enable': False},
               'external-controller': f'127.0.0.1:{controller}',
               'profile': {'store-fake-ip': False}, 'rule-providers': providers, 'rules': ['MATCH,DIRECT']}
    path = directory / 'runtime.json'
    path.write_text(json.dumps(runtime))
    with (directory / 'core.log').open('w') as log:
        process = subprocess.Popen([BINARY, '-d', str(directory), '-f', str(path)], stdout=log, stderr=log)
        try:
            for _ in range(50):
                assert process.poll() is None, (directory / 'core.log').read_text()
                try:
                    with urlopen(f'http://127.0.0.1:{controller}/providers/rules', timeout=0.5) as response:
                        loaded = json.load(response)['providers']
                    if all(loaded.get(name, {}).get('ruleCount', 0) > 0 for name in PROVIDERS):
                        query(port, 'ready.runtime.example.org', 1)
                        break
                except (TimeoutError, OSError, URLError, json.JSONDecodeError):
                    pass
                time.sleep(0.1)
            else:
                raise AssertionError('Mihomo DNS/providers did not start: ' + (directory / 'core.log').read_text())
            for domain in DOMAINS:
                assert query(port, domain, 1) > 0, f'{domain}: A must work'
                aaaa = query(port, domain, 28)
                assert (aaaa == 0) if enabled else (aaaa > 0), f'{domain}: unexpected AAAA count {aaaa}'
                if enabled:
                    assert query(port, domain, 65) == 0, f'{domain}: HTTPS IPv6 hint was not filtered'
            assert query(port, 'ordinary.runtime.example.org', 1) > 0
            assert query(port, 'ordinary.runtime.example.org', 28) > 0, 'ordinary IPv6 must remain available'
            print(f'PASS ai_ipv4_only={enabled}, filter={mode}: all five AI sets checked; ordinary IPv6 works')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def main():
    print(subprocess.check_output([BINARY, '-v'], text=True).strip())
    stopped = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
        upstream.bind(('127.0.0.1', 0))
        upstream.settimeout(0.2)
        worker = threading.Thread(target=serve_dns, args=(upstream, stopped), daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory(prefix='mihomo-ai-dns-') as directory:
                for enabled in [False, True]:
                    for mode in ['basic', 'compat']:
                        run_case(Path(directory) / f'{enabled}-{mode}',
                                 f'127.0.0.1:{upstream.getsockname()[1]}', enabled, mode)
        finally:
            stopped.set()
            worker.join(timeout=1)
    print('DNS behavior verified; this does not test proxy-server egress or traffic bypassing Mihomo.')


if __name__ == '__main__':
    main()
