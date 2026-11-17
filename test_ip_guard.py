import importlib.util
import ipaddress
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('ip_guard.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AdmissionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.g = guard.Admission(2, 8388, Path(self.tmp.name) / 'status.json')
        self.kernel = set()
        self.banned = set()
        self.transactions = []
        self.calls = []
        self.fail = False
        self.addCleanup(patch.stopall)
        patch.object(guard, 'nft', self.transaction).start()
        patch.object(guard.subprocess, 'run', self.command_run).start()

    def transaction(self, text):
        if self.fail:
            raise subprocess.CalledProcessError(1, 'nft')
        self.transactions.append(text)
        for line in text.splitlines():
            ip = line.split('{ ')[1].split()[0]
            if line.startswith('delete'):
                self.kernel.remove(ip)
            elif ' banned' in line:
                self.banned.add(ip)
            else:
                self.kernel.add(ip)

    def command_run(self, cmd, **kwargs):
        self.calls.append(cmd)
        if cmd[0] == 'ss':
            return subprocess.CompletedProcess(cmd, 0)
        entries = []
        for name, ips in [('active', self.kernel), ('banned', self.banned)]:
            for v in (4, 6):
                entries.append({'set': {'name': f'{name}{v}', 'elem': [
                    {'elem': {'val': ip, 'expires': 299000}}
                    for ip in ips if ipaddress.ip_address(ip).version == v]}})
        return subprocess.CompletedProcess(cmd, 0, json.dumps({'nftables': entries}))

    def test_user_example_and_next_newcomer(self):
        for ip in ('192.0.2.1', '192.0.2.2', '192.0.2.3', '192.0.2.4'):
            self.assertTrue(self.g.admit(ip))
            self.assertLessEqual(len(self.kernel), 2)
        self.assertEqual(list(self.g.active), ['192.0.2.1', '192.0.2.4'])
        self.assertEqual(self.g.banned.keys(), {'192.0.2.2', '192.0.2.3'})
        self.assertIn(['ss', '-K', 'dst', '192.0.2.3', 'sport', '=', ':8388'], self.calls)

    def test_existing_ip_keeps_first_admission_order(self):
        for ip in ('192.0.2.1', '192.0.2.2', '192.0.2.1', '192.0.2.3'):
            self.g.admit(ip)
        self.assertEqual(list(self.g.active), ['192.0.2.1', '192.0.2.3'])

    def test_evicted_client_auto_reconnect_does_not_kick(self):
        for ip in ('192.0.2.1', '192.0.2.2', '192.0.2.3'):
            self.g.admit(ip)
        self.assertFalse(self.g.admit('192.0.2.2'))
        self.assertEqual(self.kernel, {'192.0.2.1', '192.0.2.3'})

    def test_limit_one(self):
        self.g.limit = 1
        self.g.admit('192.0.2.1')
        self.g.admit('192.0.2.2')
        self.assertEqual(self.kernel, {'192.0.2.2'})

    def test_idle_slot_released_before_replacement(self):
        self.g.admit('192.0.2.1')
        self.g.admit('192.0.2.2')
        self.kernel.remove('192.0.2.1')  # simulated nft timeout
        self.g.admit('192.0.2.3')
        self.assertEqual(list(self.g.active), ['192.0.2.2', '192.0.2.3'])
        self.assertFalse(self.g.banned)

    def test_expired_wait_can_reconnect(self):
        self.g.limit = 1
        self.g.admit('192.0.2.1')
        self.g.admit('192.0.2.2')
        self.banned.clear()
        self.g.sync()
        self.assertTrue(self.g.admit('192.0.2.1'))
        self.assertEqual(self.kernel, {'192.0.2.1'})

    def test_ipv6_shares_limit(self):
        self.g.admit('192.0.2.1')
        self.g.admit('2001:db8::1')
        self.g.admit('2001:db8::2')
        self.assertEqual(self.kernel, {'192.0.2.1', '2001:db8::2'})
        self.assertIn('delete element inet jack_ss_iplimit active6', self.transactions[-1])

    def test_failed_atomic_update_keeps_previous_admission(self):
        self.g.admit('192.0.2.1')
        self.g.admit('192.0.2.2')
        self.fail = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.g.admit('192.0.2.3')
        self.assertEqual(self.kernel, set(self.g.active))
        self.assertEqual(len(self.g.active), 2)
        self.assertFalse(self.g.banned)


class WiringTest(unittest.TestCase):
    def test_packet_source_v4_v6(self):
        v4 = bytes([0x45]) + bytes(11) + ipaddress.ip_address('192.0.2.1').packed + bytes(4)
        v6 = bytes([0x60]) + bytes(7) + ipaddress.ip_address('2001:db8::1').packed + bytes(16)
        self.assertEqual(guard.packet_source(v4), '192.0.2.1')
        self.assertEqual(guard.packet_source(v6), '2001:db8::1')
        with self.assertRaises(ValueError): guard.packet_source(b'')

    def test_rules_only_target_node_port_both_directions(self):
        script = guard.rules(18388, True)
        for proto in ('tcp', 'udp'):
            self.assertIn(f'input {proto} dport 18388 jump admit', script)
            self.assertIn(f'output {proto} sport 18388 drop', script)
        self.assertNotIn('flush ruleset', script)
        self.assertNotIn('bypass', script)
        self.assertNotIn('udp dport', guard.rules(18388, False))

    def test_single_file_installer_embeds_same_helper(self):
        script = Path(__file__).with_name('ss.sh').read_text()
        embedded = script.split("<<'JACK_IP_GUARD_PY' || return 1\n", 1)[1].split('\nJACK_IP_GUARD_PY', 1)[0]
        self.assertEqual(embedded.rstrip(), Path(__file__).with_name('ip_guard.py').read_text().rstrip())


if __name__ == '__main__':
    unittest.main()
