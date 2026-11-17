#!/usr/bin/python3
"""JACK_SS_IP_GUARD: packet admission for this node only, no proxy decryption."""
import argparse
import collections
import ipaddress
import json
import os
import select
import signal
import socket
import subprocess
import time
from pathlib import Path

TABLE = "jack_ss_iplimit"
QUEUE = 29083
IDLE = 300
COOLDOWN = 60


def nft(script):
    return subprocess.run(["nft", "-f", "-"], input=script, text=True,
                          capture_output=True, check=True, timeout=5)


def rules(port, udp):
    ports = [f"tcp sport {port}"]  # output responses to the node's clients
    if udp:
        ports.append(f"udp sport {port}")
    inputs = [p.replace("sport", "dport") for p in ports]
    lines = [f"add table inet {TABLE}"]
    for family, kind in ((4, "ipv4_addr"), (6, "ipv6_addr")):
        for name, timeout in (("active", IDLE), ("banned", COOLDOWN)):
            lines.append(f"add set inet {TABLE} {name}{family} "
                         f"{{ type {kind}; flags dynamic,timeout; timeout {timeout}s; size 65536; }}")
    lines += [f"add chain inet {TABLE} input {{ type filter hook input priority -10; policy accept; }}",
              f"add chain inet {TABLE} output {{ type filter hook output priority -10; policy accept; }}",
              f"add chain inet {TABLE} admit"]
    for p in inputs:
        lines.append(f"add rule inet {TABLE} input {p} jump admit")
    for version, proto in ((4, "ip"), (6, "ip6")):
        lines.append(f"add rule inet {TABLE} admit {proto} saddr @banned{version} drop")
        lines.append(f"add rule inet {TABLE} admit {proto} saddr @active{version} "
                     f"update @active{version} {{ {proto} saddr timeout {IDLE}s }} return")
        for p in ports:
            lines.append(f"add rule inet {TABLE} output {p} {proto} daddr @banned{version} drop")
            lines.append(f"add rule inet {TABLE} output {p} {proto} daddr @active{version} "
                         f"update @active{version} {{ {proto} daddr timeout {IDLE}s }} return")
    # No bypass: an unavailable controller must not silently remove the limit.
    lines.append(f"add rule inet {TABLE} admit queue num {QUEUE}")
    for p in ports:
        lines.append(f"add rule inet {TABLE} output {p} drop")
    return "\n".join(lines) + "\n"


def packet_source(payload):
    if not payload:
        raise ValueError("empty packet")
    version = payload[0] >> 4
    if version == 4 and len(payload) >= 20:
        return str(ipaddress.ip_address(payload[12:16]))
    if version == 6 and len(payload) >= 40:
        return str(ipaddress.ip_address(payload[8:24]))
    raise ValueError("invalid IP packet")


class Admission:
    def __init__(self, limit, port, status):
        self.limit, self.port, self.status = limit, port, Path(status)
        self.active = collections.OrderedDict()
        self.banned = {}

    def publish(self):
        status = {"limit": self.limit, "active": list(self.active),
                  "banned": list(self.banned), "updated": time.time(),
                  "idle_seconds": IDLE, "cooldown_seconds": COOLDOWN}
        tmp = self.status.with_suffix(".new")
        tmp.write_text(json.dumps(status))
        tmp.replace(self.status)

    def sync(self):
        data = subprocess.run(["nft", "-j", "list", "table", "inet", TABLE],
                              capture_output=True, text=True, check=True, timeout=5)
        live, banned = set(), set()
        for obj in json.loads(data.stdout)["nftables"]:
            entry = obj.get("set", {})
            if not entry.get("name", "").startswith(("active", "banned")):
                continue
            target = live if entry["name"].startswith("active") else banned
            for elem in entry.get("elem", []):
                if isinstance(elem, str):
                    target.add(elem)
                elif isinstance(elem, dict):
                    value = elem.get("elem", elem).get("val")
                    if isinstance(value, str):
                        target.add(value)
        self.active = collections.OrderedDict((ip, t) for ip, t in self.active.items() if ip in live)
        self.banned = {ip: t for ip, t in self.banned.items() if ip in banned}
        self.publish()

    def admit(self, ip):
        if ip in self.banned:
            return False
        if ip in self.active:
            return True
        # A slot may have expired since the periodic status refresh.
        self.sync()
        version = ipaddress.ip_address(ip).version
        victim = next(reversed(self.active), None) if len(self.active) >= self.limit else None
        script = []
        if victim:
            family = ipaddress.ip_address(victim).version
            script += [f"delete element inet {TABLE} active{family} {{ {victim} }}",
                       f"add element inet {TABLE} banned{family} {{ {victim} timeout {COOLDOWN}s }}"]
        script.append(f"add element inet {TABLE} active{version} {{ {ip} timeout {IDLE}s }}")
        # One atomic kernel transaction: remove victim before accepting newcomer.
        nft("\n".join(script) + "\n")
        if victim:
            del self.active[victim]
            self.banned[victim] = time.monotonic()
            # Terminate only sockets on this node's listening port.
            try:
                subprocess.run(["ss", "-K", "dst", victim, "sport", "=", f":{self.port}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                # Firewall denies both directions even when socket destroy is unsupported.
                pass
        self.active[ip] = time.monotonic()
        self.publish()
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--udp", action="store_true")
    parser.add_argument("--status", default="/run/jack-ss-iplimit/status.json")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.limit <= 4096:
        parser.error("invalid port or limit")
    from netfilterqueue import NetfilterQueue
    os.umask(0o077)
    Path(args.status).parent.mkdir(parents=True, exist_ok=True)
    guard = Admission(args.limit, args.port, args.status)
    queue = NetfilterQueue()
    running = True
    failed = False

    def receive(packet):
        nonlocal running, failed
        try:
            ip = packet_source(packet.get_payload())
            allowed = guard.admit(ip)
        except Exception as exc:
            print(f"IP admission failed: {exc}", flush=True)
            packet.drop()
            # Callback exceptions can be swallowed by the C binding. Exit the loop.
            running = False
            failed = True
            return
        if allowed:
            packet.accept()
        else:
            packet.drop()

    # Bind before installing packet rules; a queue conflict leaves other rules alone.
    queue.bind(QUEUE, receive, max_len=4096)
    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Replace only our own named table. Keep an existing table on startup failure.
    existing = subprocess.run(["nft", "list", "table", "inet", TABLE],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    nft((f"delete table inet {TABLE}\n" if existing else "") + rules(args.port, args.udp))
    guard.publish()
    # Type=notify starts the SS service only after the kernel rules are installed.
    notify = os.environ.get("NOTIFY_SOCKET")
    if notify:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect("\0" + notify[1:] if notify.startswith("@") else notify)
            sock.sendall(b"READY=1")
    try:
        next_sync = time.monotonic() + 1
        while running:
            if select.select([queue.get_fd()], [], [], 1)[0]:
                queue.run(block=False)
            if time.monotonic() >= next_sync:
                guard.sync()
                next_sync = time.monotonic() + 1
    finally:
        queue.unbind()
        Path(args.status).unlink(missing_ok=True)
        # Leave rules fail-closed until restart or an explicit disable operation.
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
