"""Optional local-only TCP/UDP integration test with actual shadowsocks-libev binaries."""
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest

BIN = os.environ.get('SS_CORE_BIN_DIR')


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(1024)
        if data: self.request.sendall(data)


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


@unittest.skipUnless(BIN, 'set SS_CORE_BIN_DIR to run native TCP/UDP integration')
class NativeTest(unittest.TestCase):
    def test_two_nodes_forward_tcp_udp_and_stopping_one_preserves_other(self):
        tcp = socketserver.ThreadingTCPServer(('127.0.0.1', 0), TCPHandler)
        udp = socketserver.ThreadingUDPServer(('127.0.0.1', tcp.server_address[1]), UDPHandler)
        for server in (tcp, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        processes = []

        def cleanup():
            for process in reversed(processes):
                if process.poll() is None: process.terminate()
            for process in processes:
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        self.addCleanup(cleanup)

        def port():
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]

        def launch(argv, listen):
            p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(p)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                self.assertIsNone(p.poll(), str(argv))
                try:
                    with socket.create_connection(('127.0.0.1', listen), timeout=.1): return p
                except OSError: time.sleep(.02)
            self.fail('local core did not listen')

        local_ports, servers = [], []
        for n in (1, 2):
            directory = Path(temp.name) / f'base/nodes/{n}'; directory.mkdir(parents=True)
            remote, local = port(), port(); local_ports.append(local)
            # Generate config with the actual menu function, not a test-only schema.
            script = Path(__file__).with_name('ss.sh')
            result = subprocess.run(['bash', '-c', '''
source "$1"
BASE="$2/base"; node_context "$3"; NAME="node-$3"
HOST=127.0.0.1; LOCAL_PORT=$4; PUBLIC_PORT=$4; PASSWORD="native-secret-$3"
MODE=tcp_and_udp; METHOD=chacha20-ietf-poly1305
write_config; write_state
''', 'bash', str(script), temp.name, str(n), str(remote)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads((directory / 'config.json').read_text())
            servers.append(launch([str(Path(BIN) / 'ss-server'), '-c', str(directory / 'config.json')], remote))
            launch([str(Path(BIN) / 'ss-tunnel'), '-s', '127.0.0.1', '-p', str(remote),
                    '-l', str(local), '-L', f'127.0.0.1:{tcp.server_address[1]}',
                    '-k', config['password'], '-m', config['method'], '-u'], local)

        def check(local, payload):
            with socket.create_connection(('127.0.0.1', local), timeout=2) as sock:
                sock.settimeout(2); sock.sendall(payload); self.assertEqual(sock.recv(1024), payload)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2); sock.sendto(payload, ('127.0.0.1', local))
                self.assertEqual(sock.recv(1024), payload)

        check(local_ports[0], b'node-one')
        check(local_ports[1], b'node-two')
        servers[0].terminate(); servers[0].wait(timeout=3)
        check(local_ports[1], b'node-two-remains-online')


if __name__ == '__main__':
    unittest.main()
