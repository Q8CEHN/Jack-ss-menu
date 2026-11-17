"""Exercise real menu operations with isolated files and a fake service manager."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('ss.sh')
SETUP = r'''
source "$SCRIPT"
BASE="$TEST_DIR/base"; SYSTEMD_DIR="$TEST_DIR/units"; INIT_DIR="$TEST_DIR/init"
MENU="$TEST_DIR/s-s"; LEGACY_MENU="$TEST_DIR/old-ss"; CORE_DIR="$TEST_DIR/core"
mkdir -p "$BASE" "$SYSTEMD_DIR" "$INIT_DIR" "$TEST_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/ss-server"
chmod 755 "$TEST_DIR/bin/ss-server"
PATH="$TEST_DIR/bin:$PATH"
is_systemd() { return 0; }
systemctl() {
  printf '%s\n' "$*" >>"$TEST_DIR/service.log"
  case "$1" in
    start|restart) touch "$TEST_DIR/running-$2";;
    stop) rm -f "$TEST_DIR/running-$2";;
    is-active) [[ -f "$TEST_DIR/running-${@: -1}" ]];;
    *) return 0;;
  esac
}
sleep() { :; }
ss() { :; }
curl() { printf '127.0.0.1'; }
install_core() { :; }
firewall_add() { printf '%s\n' "$NODE_ID" >>"$TEST_DIR/firewall-added"; }
firewall_remove() { printf '%s\n' "$NODE_ID" >>"$TEST_DIR/firewall-removed"; }
ask() {
  local response
  IFS= read -r response <"$TEST_DIR/answers"
  tail -n +2 "$TEST_DIR/answers" >"$TEST_DIR/answers.new"
  mv "$TEST_DIR/answers.new" "$TEST_DIR/answers"
  printf -v "$2" '%s' "$response"
}
node_context legacy
'''


class NodesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, body, answers=()):
        (self.root / 'answers').write_text(''.join(a + '\n' for a in answers))
        result = subprocess.run(['bash', '-c', SETUP + '\n' + body], text=True,
                                capture_output=True, env={**os.environ, 'SCRIPT': str(SCRIPT), 'TEST_DIR': str(self.root)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def create_pair(self, tail=''):
        return self.shell('add_node\nadd_node\n' + tail,
                          ['first', '18388', '127.0.0.1', 'y', 'password-one',
                           'second', '18389', '127.0.0.1', 'n', 'password-two'])

    def test_create_nodes_with_separate_passwords_modes_and_units(self):
        self.create_pair()
        configs = [json.loads((self.root / f'base/nodes/{n}/config.json').read_text()) for n in (1, 2)]
        self.assertEqual([c['server_port'] for c in configs], [18388, 18389])
        self.assertEqual([c['password'] for c in configs], ['password-one', 'password-two'])
        self.assertEqual([c['mode'] for c in configs], ['tcp_and_udp', 'tcp_only'])
        for n in (1, 2):
            unit = (self.root / f'units/jack-ss-node-{n}.service').read_text()
            self.assertIn(f'base/nodes/{n}/config.json', unit)
            self.assertTrue((self.root / f'running-jack-ss-node-{n}').exists())

    def test_old_node_stays_in_place_and_new_node_is_independent(self):
        base = self.root / 'base'; base.mkdir()
        old = 'HOST=127.0.0.1\nLOCAL_PORT=8388\nPUBLIC_PORT=8388\nPASSWORD=old-secret\nMODE=tcp_only\nMETHOD=chacha20-ietf-poly1305\n'
        (base / 'settings').write_text(old)
        (base / 'config.json').write_text('{"old":"untouched"}')
        self.shell('add_node\nnode_ids', ['new', '18389', '', 'n', 'new-secret'])
        self.assertEqual((base / 'settings').read_text(), old)
        self.assertEqual((base / 'config.json').read_text(), '{"old":"untouched"}')
        self.assertEqual(json.loads((base / 'nodes/1/config.json').read_text())['password'], 'new-secret')
        self.assertNotIn('stop jack-ss\n', (self.root / 'service.log').read_text())

    def test_limits_have_distinct_services_backends_and_status(self):
        self.create_pair('''
for id in 1 2; do
  node_context "$id"; printf '%s\n' "$((id + 1))" >"$ROOT/ip-limit"; iplimit_apply
done
''')
        for n, cap in ((1, 2), (2, 3)):
            service = f'jack-ss-iplimit-node-{n}'
            unit = (self.root / f'units/{service}.service').read_text()
            self.assertIn(f'--limit {cap}', unit)
            self.assertIn('--backend ', unit)
            self.assertNotIn('CAP_NET_ADMIN', unit)
            self.assertIn('Restart=always', unit)
            self.assertIn('StartLimitIntervalSec=0', unit)
            self.assertIn(f'ExecStartPost=/usr/bin/systemctl --no-block start jack-ss-node-{n}.service', unit)
            self.assertNotIn('--queue', unit)
            self.assertIn(f'--status /run/{service}/status.json', unit)
            dropin = (self.root / f'units/jack-ss-node-{n}.service.d/iplimit.conf').read_text()
            self.assertIn(f'Requires={service}.service', dropin)

    def test_disabling_one_limit_preserves_other_node(self):
        self.create_pair('''
for id in 1 2; do node_context "$id"; echo 2 >"$ROOT/ip-limit"; iplimit_apply; done
node_context 1; iplimit_disable
''')
        self.assertFalse((self.root / 'base/nodes/1/ip-limit').exists())
        self.assertTrue((self.root / 'base/nodes/2/ip-limit').exists())
        self.assertTrue((self.root / 'units/jack-ss-iplimit-node-2.service').exists())
        self.assertTrue((self.root / 'running-jack-ss-iplimit-node-2').exists())
        restored = json.loads((self.root / 'base/nodes/1/config.json').read_text())
        self.assertEqual(restored['server_port'], 18388)
        self.assertEqual(restored['server'], '0.0.0.0')
        self.assertFalse((self.root / 'base/nodes/1/ip-backend-port').exists())

    def test_failed_relay_start_keeps_limit_and_private_backend(self):
        self.create_pair()
        self.shell('''
systemctl() {
  case "$1" in
    start) touch "$TEST_DIR/running-$2";;
    restart) return 1;;
    stop) rm -f "$TEST_DIR/running-$2";;
    is-active) [[ -f "$TEST_DIR/running-${@: -1}" ]];;
    *) return 0;;
  esac
}
journalctl() { echo 'simulated relay startup error'; }
node_context 1
iplimit_menu
''', ['1', '2', '', '0'])
        restored=json.loads((self.root/'base/nodes/1/config.json').read_text())
        backend=int((self.root/'base/nodes/1/ip-backend-port').read_text())
        self.assertEqual(restored['server_port'],backend)
        self.assertEqual(restored['server'],'127.0.0.1')
        self.assertEqual(restored['password'],'password-one')
        self.assertEqual((self.root/'base/nodes/1/ip-limit').read_text().strip(),'2')
        self.assertTrue((self.root/'units/jack-ss-iplimit-node-1.service').exists())
        self.assertFalse((self.root/'running-jack-ss-node-1').exists())

    def test_duplicate_port_rejected_before_stopping_any_node(self):
        self.create_pair()
        before = (self.root / 'base/nodes/1/config.json').read_bytes()
        log = (self.root / 'service.log').read_bytes()
        self.shell('node_context 1\nchange_settings ports', ['18389'])
        self.assertEqual((self.root / 'base/nodes/1/config.json').read_bytes(), before)
        self.assertEqual((self.root / 'service.log').read_bytes(), log)

    def test_delete_one_node_preserves_other_node(self):
        self.create_pair('node_context 1\nload_state\nremove_node_resources')
        self.assertFalse((self.root / 'base/nodes/1').exists())
        self.assertTrue((self.root / 'base/nodes/2/config.json').exists())
        self.assertTrue((self.root / 'running-jack-ss-node-2').exists())
        self.assertEqual((self.root / 'firewall-removed').read_text(), '1\n')

    def test_edit_one_password_does_not_change_other_node(self):
        self.create_pair()
        second = (self.root / 'base/nodes/2/config.json').read_bytes()
        self.shell('node_context 1\nchange_settings password', ['changed-password'])
        self.assertEqual(json.loads((self.root / 'base/nodes/1/config.json').read_text())['password'], 'changed-password')
        self.assertEqual((self.root / 'base/nodes/2/config.json').read_bytes(), second)

    def test_whole_uninstall_stops_all_nodes_and_removes_all_owned_units(self):
        self.create_pair()
        self.shell('''
iplimit_remove_deps() { :; }
remove_core() { :; }
uninstall_node
''', ['YES'])
        self.assertFalse((self.root / 'base').exists())
        self.assertEqual(list((self.root / 'units').glob('jack-ss*.service')), [])
        self.assertEqual(list(self.root.glob('running-jack-ss*')), [])


if __name__ == '__main__':
    unittest.main()
