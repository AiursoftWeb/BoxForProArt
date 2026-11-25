import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / 'stage4/images/worker'
SPEC = importlib.util.spec_from_file_location('configure_copilot', WORKER / 'configure-copilot.py')
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)


class CopilotHomeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / 'home'
        self.home.mkdir()
        self.launcher = Path('/opt/worker-tools/copilot-cici-super-happier')

    def configure(self):
        CONFIGURE.configure(self.home, WORKER / 'copilot-home', self.launcher)

    def test_fresh_home_has_private_defaults_and_image_launcher(self):
        self.configure()
        config = self.home / '.copilot-cici-super'
        self.assertEqual(config.stat().st_mode & 0o777, 0o700)
        settings = json.loads((config / 'settings.json').read_text())
        self.assertEqual(settings['effortLevel'], 'xhigh')
        self.assertTrue(settings['showReasoning'])
        self.assertEqual((config / 'settings.json').stat().st_mode & 0o777, 0o600)
        self.assertIn('/home/anduin/CICI/AGENTS.md', (config / 'copilot-instructions.md').read_text())
        self.assertEqual((self.home / '.local/bin/copilot-cici-super-happier').readlink(), self.launcher)
        self.assertFalse((self.home / '.config/cici/ollama-api-key').exists())

    def test_existing_initialized_home_keeps_settings_instructions_and_key(self):
        (self.home / '.worker-home-initialized').touch()
        self.configure()
        config = self.home / '.copilot-cici-super'
        (config / 'settings.json').write_text('{"effortLevel":"high","custom":true}')
        (config / 'copilot-instructions.md').write_text('user instruction')
        key = self.home / '.config/cici/ollama-api-key'
        key.parent.mkdir(parents=True)
        key.write_text('fixture-key-never-in-image')
        self.configure()
        self.assertEqual(json.loads((config / 'settings.json').read_text()),
                         {'effortLevel': 'high', 'custom': True})
        self.assertEqual((config / 'copilot-instructions.md').read_text(), 'user instruction')
        self.assertEqual(key.read_text(), 'fixture-key-never-in-image')

    def test_previously_provisioned_launcher_migrates_from_home_binary(self):
        path = self.home / '.local/bin/copilot-cici-super-happier'
        path.parent.mkdir(parents=True)
        path.write_text('#!/usr/bin/env bash\nset -euo pipefail\n'
                        f'exec {self.home}/.local/bin/copilot --effort=xhigh '
                        '--max-autopilot-continues=20 --no-auto-update "$@"\n')
        self.configure()
        self.configure()
        self.assertEqual(path.readlink(), self.launcher)

    def test_custom_launcher_is_preserved(self):
        path = self.home / '.local/bin/copilot-cici-super-happier'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'custom launcher\xff')
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.configure()
        self.assertEqual(path.read_bytes(), b'custom launcher\xff')
        self.assertIn('Keeping custom Copilot launcher', output.getvalue())

    def test_legacy_native_history_is_imported_without_overwriting_sessions_or_credentials(self):
        legacy = self.home / '.copilot/session-state/legacy-session'
        legacy.mkdir(parents=True)
        (legacy / 'events.jsonl').write_text('original conversation')
        (self.home / '.copilot/config.json').write_text('private credential fixture')
        self.configure()
        destination = self.home / '.copilot-cici-super/session-state/legacy-session/events.jsonl'
        self.assertEqual(destination.read_text(), 'original conversation')
        self.assertTrue((legacy / 'events.jsonl').exists())
        self.assertFalse((self.home / '.copilot-cici-super/config.json').exists())
        destination.write_text('newer continued conversation')
        self.configure()
        self.assertEqual(destination.read_text(), 'newer continued conversation')
        self.assertFalse(list(destination.parent.parent.glob('.native-import-*')))

    def test_runtime_credential_binding_overrides_the_private_file_without_logging_it(self):
        key = self.home / '.config/cici/ollama-api-key'
        key.parent.mkdir(parents=True)
        key.write_text('fixture-file-key')
        env = {k: v for k, v in os.environ.items()
               if k not in ['COPILOT_PROVIDER_API_KEY', 'COPILOT_PROVIDER_BEARER_TOKEN']}
        env['HOME'] = str(self.home)
        cases = [({}, 'fixture-file-key'),
                 ({'COPILOT_PROVIDER_API_KEY': 'fixture-vault-key'}, 'fixture-vault-key'),
                 ({'COPILOT_PROVIDER_API_KEY': 'fixture-vault-key',
                   'COPILOT_PROVIDER_BEARER_TOKEN': 'fixture-token'}, 'fixture-token')]
        for extra, expected in cases:
            with self.subTest(extra=list(extra)):
                result = subprocess.run(['bash', str(WORKER / 'copilot-provider-key.sh')],
                                        env={**env, **extra}, capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
