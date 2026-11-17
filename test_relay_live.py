"""Real TCP/UDP IP-cap tests using loopback source addresses; no NET_ADMIN."""
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

class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while data:=self.request.recv(65536): self.request.sendall(data)
        except OSError: pass

class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data,sock=self.request; sock.sendto(data,self.client_address)

class LiveRelayTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.tcp=socketserver.ThreadingTCPServer(('127.0.0.1',0),TCP)
        self.tcp.daemon_threads=True
        self.udp=socketserver.ThreadingUDPServer(('127.0.0.1',self.tcp.server_address[1]),UDP)
        self.udp.max_packet_size=65535
        for server in (self.tcp,self.udp):
            threading.Thread(target=server.serve_forever,daemon=True).start()
            self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        self.processes=[]
        self.addCleanup(self.stop)

    def stop(self):
        for p in self.processes:
            if p.poll() is None: p.terminate()
        for p in self.processes:
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill(); p.wait()

    def launch(self,limit,bind='127.0.0.1'):
        with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
        status=Path(self.tmp.name)/f'status-{port}.json'
        log=open(Path(self.tmp.name)/f'log-{port}','w+')
        self.addCleanup(log.close)
        p=subprocess.Popen(['/usr/bin/python3',str(Path(__file__).with_name('ip_guard.py')),
            '--port',str(port),'--backend',str(self.tcp.server_address[1]),'--bind',bind,
            '--limit',str(limit),'--udp','--status',str(status)],stdout=log,stderr=log)
        self.processes.append(p)
        deadline=time.monotonic()+3
        while not status.exists() and time.monotonic()<deadline:
            if p.poll() is not None: log.seek(0); self.fail(log.read())
            time.sleep(.01)
        self.assertTrue(status.exists())
        return port,status

    def connect(self,port,source):
        s=socket.socket(); s.settimeout(2); s.bind((source,0)); s.connect(('127.0.0.1',port))
        self.addCleanup(s.close)
        self.echo(s,source.encode())
        return s

    def echo(self,s,data):
        s.sendall(data)
        received=b''
        while len(received)<len(data):
            part=s.recv(len(data)-len(received))
            self.assertTrue(part)
            received+=part
        self.assertEqual(received,data)

    def assert_closed(self,s):
        try: self.assertEqual(s.recv(1),b'')
        except (ConnectionResetError,BrokenPipeError): pass

    def udp_echo(self,port,source,data,allowed=True):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
            s.settimeout(.3 if not allowed else 2); s.bind((source,0)); s.sendto(data,('127.0.0.1',port))
            if allowed: self.assertEqual(s.recv(65535),data)
            else:
                with self.assertRaises(socket.timeout): s.recv(65535)

    def test_third_ip_kicks_second_tcp_and_reconnect_is_blocked(self):
        port,_=self.launch(2)
        a=self.connect(port,'127.0.0.2'); b=self.connect(port,'127.0.0.3'); c=self.connect(port,'127.0.0.4')
        self.assert_closed(b)
        self.echo(a,b'first-kept'); self.echo(c,b'new-kept')
        retry=socket.socket(); self.addCleanup(retry.close); retry.settimeout(2)
        retry.bind(('127.0.0.3',0)); retry.connect(('127.0.0.1',port))
        self.assert_closed(retry)
        self.echo(c,b'no-ping-pong')
        self.echo(a,b'x'*262144)

    def test_udp_new_ip_shares_cap_and_kicks_tcp(self):
        port,_=self.launch(2)
        a=self.connect(port,'127.0.0.2'); b=self.connect(port,'127.0.0.3')
        self.udp_echo(port,'127.0.0.4',b'udp-replacement')
        self.assert_closed(b); self.echo(a,b'first-still-works')
        self.udp_echo(port,'127.0.0.3',b'blocked',False)
        self.udp_echo(port,'127.0.0.4',b'z'*60000)

    def test_same_source_ip_is_counted_separately_on_two_nodes(self):
        first,_=self.launch(2); second,_=self.launch(1)
        a=self.connect(first,'127.0.0.2'); b=self.connect(first,'127.0.0.3')
        other=self.connect(second,'127.0.0.2'); replacement=self.connect(second,'127.0.0.4')
        self.assert_closed(other)
        self.echo(a,b'node-one-A'); self.echo(b,b'node-one-B')
        self.echo(replacement,b'node-two-C')
        self.processes[1].terminate(); self.processes[1].wait(timeout=3)
        self.echo(a,b'node-one-unaffected-by-node-two-stop')

    def test_dual_stack_listener_handles_ipv4_and_ipv6(self):
        if not socket.has_ipv6: self.skipTest('no IPv6')
        try:
            with socket.socket(socket.AF_INET6) as check: check.bind(('::1',0))
        except OSError: self.skipTest('no loopback IPv6')
        port,_=self.launch(2,'::')
        v4=self.connect(port,'127.0.0.2')
        v6=socket.socket(socket.AF_INET6); self.addCleanup(v6.close); v6.settimeout(2); v6.connect(('::1',port))
        self.echo(v6,b'ipv6'); self.echo(v4,b'ipv4')

if __name__=='__main__': unittest.main()
