import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('guard',Path(__file__).with_name('ip_guard.py'))
guard=importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)

class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.now=0
        self.evicted=[]
        self.g=guard.Admission(2,self.evicted.append,lambda:self.now)

    def test_new_ip_replaces_most_recent_admission(self):
        for ip in ('A','B','C','D'): self.assertTrue(self.g.admit(ip))
        self.assertEqual(list(self.g.active),['A','D'])
        self.assertEqual(self.evicted,['B','C'])

    def test_existing_connections_do_not_reorder(self):
        for ip in ('A','B','A','C'): self.g.admit(ip)
        self.assertEqual(list(self.g.active),['A','C'])

    def test_evicted_ip_reconnect_cannot_kick_new_client(self):
        for ip in ('A','B','C'): self.g.admit(ip)
        self.assertFalse(self.g.admit('B'))
        self.assertEqual(list(self.g.active),['A','C'])

    def test_waiting_expires(self):
        for ip in ('A','B','C'): self.g.admit(ip)
        self.now=61
        self.assertTrue(self.g.admit('B'))
        self.assertEqual(list(self.g.active),['A','B'])

    def test_idle_expiry_frees_slot(self):
        self.g.admit('A'); self.now=100; self.g.admit('B'); self.now=301
        self.g.admit('C')
        self.assertEqual(list(self.g.active),['B','C'])
        self.assertEqual(self.evicted,['A'])

    def test_two_nodes_keep_independent_limits_and_bans(self):
        second=guard.Admission(1)
        for ip in ('A','B','C'): self.g.admit(ip)
        second.admit('A'); second.admit('B')
        self.assertTrue(self.g.admit('A')); self.assertFalse(second.admit('A'))
        self.assertFalse(self.g.admit('B')); self.assertTrue(second.admit('B'))

    def test_ipv4_mapped_address_counted_as_same_ipv4(self):
        self.assertEqual(guard.normalize_ip('::ffff:192.0.2.1'),'192.0.2.1')
        self.assertEqual(guard.normalize_ip('2001:db8::1'),'2001:db8::1')

    def test_embedded_helper_matches_source(self):
        script=Path(__file__).with_name('ss.sh').read_text()
        embedded=script.split("<<'JACK_IP_GUARD_PY' || return 1\n",1)[1].split('\nJACK_IP_GUARD_PY',1)[0]
        self.assertEqual(embedded.rstrip(),Path(__file__).with_name('ip_guard.py').read_text().rstrip())

if __name__=='__main__': unittest.main()
