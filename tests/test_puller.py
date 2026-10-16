"""Offline regression tests for public image synchronization and its wrapper."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PULLER = ROOT / "stage3/images/puller"

REGCTL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ['FIXTURE_STATE'])
state = json.loads(path.read_text())
with open(os.environ['FIXTURE_CALLS'], 'a') as out:
    out.write(json.dumps(args) + '\n')
if args[:2] == ['registry', 'login']:
    sys.exit(0)
operation, ref = args[1:3]
mode = os.environ.get('FIXTURE_MODE', 'success')
target = ref.startswith('mirror.invalid/')
name = ref.split('/')[-1].split(':')[0].split('@')[0]
old, new = 'sha256:' + '1' * 64, 'sha256:' + '2' * 64
if operation == 'digest':
    if target:
        value = state.get(name)
        if value is None: sys.exit(1)
        print(value)
    elif mode == 'source_unavailable': sys.exit(21)
    elif mode != 'empty_source': print(new)
    sys.exit(0)
if operation == 'manifest':
    sys.exit(1 if mode == 'manifest_failure' or name not in state else 0)
if operation == 'copy':
    dst = args[3].split('/')[-1].split(':')[0]
    count = state.get('_copies', 0) + 1
    state['_copies'] = count
    failure = (mode == 'copy_failure' or (mode == 'one_failure' and dst == 'bad')
               or (mode == 'recover' and count == 1))
    if not failure and mode != 'stale_target': state[dst] = new
    path.write_text(json.dumps(state))
    sys.exit(42 if failure else 0)
sys.exit(99)
'''


class PullerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.app.mkdir()
        (self.app / 'source_updated.py').write_text(
            'import os, sys\nsys.exit(0 if os.environ.get("FIXTURE_SKIP") == "1" else 1)\n')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        scripts = {
            'regctl': REGCTL,
            'sleep': '#!/bin/sh\nexit 0\n',
            'shuf': '#!/bin/sh\ncat\n',
            'pgrep': '#!/bin/sh\nexit 1\n',
            'mv': '#!/bin/sh\nif [ "$FIXTURE_RECORD_FAILURE" = 1 ]; then exit 74; fi\nexec /usr/bin/mv "$@"\n',
            'timeout': '#!/bin/sh\nif [ "$FIXTURE_TIMEOUT" = 1 ]; then exit 124; fi\nprintf "%s\\n" "$1" >> "$FIXTURE_TIMEOUTS"\nshift\nexec "$@"\n',
        }
        for name, text in scripts.items():
            p = self.bin / name
            p.write_text(text)
            p.chmod(0o755)
        self.state = self.root / 'state.json'
        self.state.write_text('{}')
        self.calls = self.root / 'calls.jsonl'
        self.records = self.root / 'records'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        APP_DIR=str(self.app), REGCTL_BIN=str(self.bin / 'regctl'),
                        SYNC_RECORDS_DIR=str(self.records), MIRROR_TARGET='mirror.invalid',
                        FROM_REGISTRY='', DOCKER_USERNAME='', DOCKER_PASSWORD='',
                        DOCKERHUB_USERNAME='fixture', DOCKERHUB_PASSWORD='fixture',
                        MAX_ATTEMPTS='1', FIXTURE_STATE=str(self.state),
                        FIXTURE_CALLS=str(self.calls), FIXTURE_TIMEOUTS=str(self.root / 'timeouts'))

    def run_puller(self, mode='success', images=('example/app',), **env):
        return subprocess.run(['bash', str(PULLER / 'entry.sh'), *images],
                              env=dict(self.env, FIXTURE_MODE=mode, **env),
                              text=True, capture_output=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def record(self, name='example/app'):
        return self.records / (name.replace('/', '__') + '_latest')

    def seed_old(self):
        self.state.write_text(json.dumps({'app': 'sha256:' + '1' * 64}))

    def assert_failed_without_record(self, mode):
        self.seed_old()
        result = self.run_puller(mode)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record().exists())
        self.assertNotIn('mirrored successfully', result.stdout)
        self.assertFalse(any(c[:2] == ['image', 'delete'] for c in self.commands()))
        return result

    def test_unavailable_source_cannot_use_old_cache(self):
        self.assert_failed_without_record('source_unavailable')
        self.assertFalse(any(c[:2] == ['image', 'copy'] for c in self.commands()))

    def test_empty_source_digest_is_failure(self):
        self.assert_failed_without_record('empty_source')

    def test_copy_failure_is_not_hidden_by_sed_or_old_cache(self):
        self.assert_failed_without_record('copy_failure')

    def test_successful_copy_must_produce_expected_digest(self):
        self.assert_failed_without_record('stale_target')

    def test_manifest_failure_preserves_target(self):
        self.assert_failed_without_record('manifest_failure')
        self.assertEqual(json.loads(self.state.read_text())['app'], 'sha256:' + '2' * 64)

    def test_missing_target_is_copied_and_verified(self):
        result = self.run_puller()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.record().read_text().split()
        self.assertTrue(record[0].isdigit())
        self.assertEqual(record[1], 'sha256:' + '2' * 64)
        copies = [c for c in self.commands() if c[:2] == ['image', 'copy']]
        self.assertEqual(copies[0][2], 'example/app@sha256:' + '2' * 64)
        self.assertEqual((self.root / 'timeouts').read_text().strip(), '14400')

    def test_already_matching_target_needs_no_copy(self):
        self.state.write_text(json.dumps({'app': 'sha256:' + '2' * 64}))
        result = self.run_puller()
        self.assertEqual(result.returncode, 0)
        self.assertTrue(self.record().exists())
        self.assertFalse(any(c[:2] == ['image', 'copy'] for c in self.commands()))

    def test_failure_does_not_update_existing_success_record(self):
        self.records.mkdir()
        self.record().write_text('123 sha256:previous\n')
        self.run_puller('copy_failure')
        self.assertEqual(self.record().read_text(), '123 sha256:previous\n')

    def test_old_timestamp_only_record_cannot_skip_failure(self):
        self.records.mkdir()
        self.record().write_text('123\n')
        result = self.run_puller('source_unavailable', FIXTURE_SKIP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.record().read_text(), '123\n')

    def test_verified_unchanged_record_can_skip(self):
        self.seed_old()
        self.records.mkdir()
        self.record().write_text('123 sha256:' + '1' * 64 + '\n')
        result = self.run_puller('source_unavailable', FIXTURE_SKIP='1')
        self.assertEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ['image', 'copy'] for c in self.commands()))

    def test_retry_can_recover_and_records_verified_success(self):
        result = self.run_puller('recover', MAX_ATTEMPTS='2')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.record().exists())
        copies = [c for c in self.commands() if c[:2] == ['image', 'copy']]
        self.assertEqual(len(copies), 2)
        self.assertIn('--force-recursive', copies[1])

    def test_failed_image_does_not_prevent_other_images(self):
        result = self.run_puller('one_failure', images=('example/bad', 'example/good'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('1 image(s) failed: example/bad', result.stdout)
        self.assertTrue(self.record('example/good').exists())
        self.assertFalse(self.record('example/bad').exists())

    def test_timed_out_copy_preserves_previous_success_record(self):
        self.seed_old()
        self.records.mkdir()
        self.record().write_text('123 sha256:previous\n')
        result = self.run_puller(FIXTURE_TIMEOUT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.record().read_text(), '123 sha256:previous\n')

    def test_record_write_failure_is_not_success(self):
        self.records.mkdir()
        self.record().write_text('123 sha256:previous\n')
        result = self.run_puller(FIXTURE_RECORD_FAILURE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.record().read_text(), '123 sha256:previous\n')

    def test_changed_target_cannot_use_verified_skip_record(self):
        self.seed_old()
        self.records.mkdir()
        self.record().write_text('123 sha256:' + '2' * 64 + '\n')
        result = self.run_puller('source_unavailable', FIXTURE_SKIP='1')
        self.assertNotEqual(result.returncode, 0)

    def test_custom_copy_timeout_is_used(self):
        result = self.run_puller(COPY_TIMEOUT_SECONDS='7200')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / 'timeouts').read_text().strip(), '7200')

    def test_invalid_retry_limit_fails_before_work(self):
        result = self.run_puller(MAX_ATTEMPTS='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_wrapper_returns_child_failure(self):
        child = self.app / 'entry.sh'
        child.write_text('#!/bin/sh\nexit 23\n')
        child.chmod(0o755)
        env = dict(self.env, RUN_LOGS_DIR=str(self.root / 'logs'))
        result = subprocess.run(['bash', str(PULLER / 'start.sh')], env=env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 23)
        self.assertIn('exit code 23', result.stdout)


if __name__ == '__main__':
    unittest.main()
