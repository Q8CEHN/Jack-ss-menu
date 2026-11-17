#!/usr/bin/python3
"""JACK_SS_IP_GUARD: per-node encrypted TCP/UDP relay, without kernel queues."""
import argparse
import asyncio
import collections
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import time

IDLE = 300
COOLDOWN = 60


def normalize_ip(value):
    ip = ipaddress.ip_address(value)
    return str(ip.ipv4_mapped or ip) if isinstance(ip, ipaddress.IPv6Address) else str(ip)


class Admission:
    def __init__(self, limit, evict=lambda ip: None, clock=time.monotonic):
        self.limit, self.evict, self.clock = limit, evict, clock
        self.active = collections.OrderedDict()
        self.banned = {}

    def expire(self):
        now = self.clock()
        for ip, touched in list(self.active.items()):
            if now - touched >= IDLE:
                del self.active[ip]
                self.evict(ip)
        self.banned = {ip: until for ip, until in self.banned.items() if until > now}

    def admit(self, ip):
        self.expire()
        if ip in self.banned:
            return False
        if ip in self.active:
            self.active[ip] = self.clock()
            return True
        if len(self.active) >= self.limit:
            victim, _ = self.active.popitem(last=True)
            self.banned[victim] = self.clock() + COOLDOWN
            self.evict(victim)
        self.active[ip] = self.clock()
        return True

    def touch(self, ip):
        if ip in self.active:
            self.active[ip] = self.clock()


class Reply(asyncio.DatagramProtocol):
    def __init__(self, relay, key, ip):
        self.relay, self.key, self.ip = relay, key, ip

    def datagram_received(self, data, _):
        if self.ip in self.relay.admission.active:
            self.relay.admission.touch(self.ip)
            self.relay.udp_touched[self.key] = time.monotonic()
            self.relay.front_udp.sendto(data, self.key)


class FrontUDP(asyncio.DatagramProtocol):
    def __init__(self, relay):
        self.relay = relay

    def datagram_received(self, data, address):
        r = self.relay
        ip = normalize_ip(address[0])
        if not r.admission.admit(ip):
            return
        r.udp_touched[address] = time.monotonic()
        if address in r.udp_sessions:
            r.udp_sessions[address].sendto(data)
        elif address in r.pending_udp:
            r.pending_udp[address].append(data)
        else:
            r.pending_udp[address] = collections.deque([data], maxlen=32)
            task = asyncio.create_task(r.new_udp(address, ip))
            r.udp_tasks.add(task)
            task.add_done_callback(r.udp_tasks.discard)


class Relay:
    def __init__(self, limit, backend, status):
        self.backend, self.status = backend, Path(status)
        self.tcp_writers = collections.defaultdict(set)
        self.udp_sessions, self.udp_touched, self.pending_udp = {}, {}, {}
        self.udp_tasks = set()
        self.front_udp = None
        self.admission = Admission(limit, self.evict)

    def evict(self, ip):
        for writer in self.tcp_writers.pop(ip, set()):
            writer.close()
        for address in list(set(self.udp_sessions) | set(self.pending_udp)):
            if normalize_ip(address[0]) == ip:
                transport = self.udp_sessions.pop(address, None)
                if transport:
                    transport.close()
                self.pending_udp.pop(address, None)
                self.udp_touched.pop(address, None)

    def publish(self):
        data = {'limit': self.admission.limit, 'active': list(self.admission.active),
                'banned': list(self.admission.banned), 'updated': time.time(),
                'idle_seconds': IDLE, 'cooldown_seconds': COOLDOWN}
        temp = self.status.with_suffix('.new')
        temp.write_text(json.dumps(data))
        temp.replace(self.status)

    async def tcp_client(self, reader, writer):
        ip = normalize_ip(writer.get_extra_info('peername')[0])
        if not self.admission.admit(ip):
            writer.close()
            return
        writers = self.tcp_writers[ip]
        writers.add(writer)
        upstream, pumps = None, []
        try:
            incoming, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.backend), 5)
            if ip not in self.admission.active or writer.is_closing():
                return
            writers.add(upstream)

            async def pump(source, destination):
                while data := await source.read(65536):
                    if ip not in self.admission.active:
                        return
                    self.admission.touch(ip)
                    destination.write(data)
                    await destination.drain()
                with contextlib.suppress(OSError, RuntimeError):
                    destination.write_eof()

            pumps = [asyncio.create_task(pump(reader, upstream)), asyncio.create_task(pump(incoming, writer))]
            await asyncio.gather(*pumps)
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            for task in pumps:
                task.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            writer.close()
            writers.discard(writer)
            if upstream:
                upstream.close()
                writers.discard(upstream)
            if not writers and self.tcp_writers.get(ip) is writers:
                self.tcp_writers.pop(ip, None)

    async def new_udp(self, address, ip):
        transport = None
        try:
            transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: Reply(self, address, ip), remote_addr=('127.0.0.1', self.backend))
            pending = self.pending_udp.pop(address, None)
            if pending is None or ip not in self.admission.active:
                transport.close()
                return
            self.udp_sessions[address] = transport
            for data in pending:
                transport.sendto(data)
        except OSError:
            if transport:
                transport.close()
            self.pending_udp.pop(address, None)
            self.udp_touched.pop(address, None)

    async def maintain(self):
        while True:
            self.admission.expire()
            for address, touched in list(self.udp_touched.items()):
                if time.monotonic() - touched >= IDLE:
                    transport = self.udp_sessions.pop(address, None)
                    if transport:
                        transport.close()
                    self.udp_touched.pop(address, None)
            self.publish()
            await asyncio.sleep(1)


def bound_socket(host, port, kind):
    family = socket.AF_INET6 if ':' in host else socket.AF_INET
    sock = socket.socket(family, kind)
    try:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        if kind == socket.SOCK_STREAM:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close()
        raise


async def run(args):
    os.umask(0o077)
    Path(args.status).parent.mkdir(parents=True, exist_ok=True)
    relay = Relay(args.limit, args.backend, args.status)
    server = await asyncio.start_server(relay.tcp_client, sock=bound_socket(args.bind, args.port, socket.SOCK_STREAM))
    maintenance = stopped = None
    try:
        if args.udp:
            relay.front_udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: FrontUDP(relay), sock=bound_socket(args.bind, args.port, socket.SOCK_DGRAM))
        relay.publish()
        notify = os.environ.get('NOTIFY_SOCKET')
        if notify:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
                sock.connect('\0' + notify[1:] if notify.startswith('@') else notify)
                sock.sendall(b'READY=1')
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        maintenance = asyncio.create_task(relay.maintain())
        stopped = asyncio.create_task(stop.wait())
        done, _ = await asyncio.wait([maintenance, stopped], return_when=asyncio.FIRST_COMPLETED)
        if maintenance in done:
            maintenance.result()
    finally:
        server.close()
        # Python 3.13 waits for accepted connections too: close them first.
        for ip in list(relay.tcp_writers):
            relay.evict(ip)
        await server.wait_closed()
        tasks = [task for task in (maintenance, stopped) if task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for transport in relay.udp_sessions.values():
            transport.close()
        if relay.front_udp:
            relay.front_udp.close()
        for task in list(relay.udp_tasks):
            task.cancel()
        await asyncio.gather(*relay.udp_tasks, return_exceptions=True)
        Path(args.status).unlink(missing_ok=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--backend', type=int, required=True)
    p.add_argument('--limit', type=int, required=True)
    p.add_argument('--bind', default='0.0.0.0')
    p.add_argument('--udp', action='store_true')
    p.add_argument('--status', required=True)
    args = p.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.backend <= 65535 or args.port == args.backend or not 1 <= args.limit <= 4096:
        p.error('invalid port or IP limit')
    try:
        asyncio.run(run(args))
    except OSError as exc:
        raise SystemExit(f'IP relay could not start: {exc}') from exc


if __name__ == '__main__':
    main()
