"""Exercise the real updater with a local download transport, without host mutations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class UpdateTest(unittest.TestCase):
    def update(self, downloaded, download_failed=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            menu = root / 's-s'
            original = '# JACK_SS_MENU\nVERSION=2.1.1\n'
            menu.write_text(original)
            (root / 'fixture').write_text(downloaded)
            (root / 'settings').write_text('PASSWORD=unchanged\nLOCAL_PORT=8388\n')
            result = subprocess.run(['bash', '-c', '''
source ./ss.sh
MENU="$TEST_DIR/s-s"
curl() {
  [[ "$DOWNLOAD_FAILED" != 1 ]] || return 22
  local destination=''
  while (( $# )); do
    if [[ "$1" == -o ]]; then destination=$2; shift; fi
    shift
  done
  cp "$TEST_DIR/fixture" "$destination"
}
fetch_menu_update
'''], cwd=Path(__file__).parent, text=True, capture_output=True,
                env={**os.environ, 'TEST_DIR': temp, 'DOWNLOAD_FAILED': str(int(download_failed))})
            self.assertEqual((root / 'settings').read_text(), 'PASSWORD=unchanged\nLOCAL_PORT=8388\n')
            self.assertEqual(list(root.glob('s-s.update.*')), [])
            return result, menu.read_text(), menu.stat().st_mode & 0o777, original

    def test_installs_new_menu_without_changing_node_configuration(self):
        content = '# JACK_SS_MENU\nVERSION=2.1.2\necho ready\n'
        result, actual, mode, _ = self.update(content)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(actual, content)
        self.assertEqual(mode, 0o755)

    def test_failed_download_preserves_installed_menu(self):
        result, actual, _, original = self.update('', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(actual, original)

    def test_invalid_download_preserves_installed_menu(self):
        for content in ('<html>error</html>', '# JACK_SS_MENU\nVERSION=2.1.2\nif then'):
            with self.subTest(content=content):
                result, actual, _, original = self.update(content)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(actual, original)

    def test_downgrade_preserves_installed_menu(self):
        result, actual, _, original = self.update('# JACK_SS_MENU\nVERSION=2.0.3\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(actual, original)


if __name__ == '__main__':
    unittest.main()
