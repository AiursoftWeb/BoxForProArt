"""Run with python3 -m unittest discover -s tests. No Docker or network required."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class CnPullerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="puller-cn-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = Path(__file__).resolve().parents[1] / "stage3/images/puller_cn"
        for name in ("entry.sh", "start.sh", "force-update.sh"):
            destination = self.root / name
            shutil.copyfile(scripts / name, destination)
            destination.chmod(0o700)
        self.records = self.root / "records"
        self.records.mkdir()
        self.log = self.root / "regctl.jsonl"
        self.regctl = self.root / "regctl"
        self.regctl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['registry', 'login']:
    sys.exit(0)
if os.environ.get('FAKE_FAIL') == '1':
    sys.exit(1)
state_file = pathlib.Path(os.environ['FAKE_STATE'])
state = json.loads(state_file.read_text()) if state_file.exists() else {}
if args[:2] == ['image', 'digest']:
    digest = 'sha256:' + 'a' * 64 if args[2].startswith('home.test/') else state.get(args[2])
    if not digest: sys.exit(1)
    print(digest)
elif args[:2] == ['image', 'copy']:
    state[args[3]] = args[2].split('@')[1]
    state_file.write_text(json.dumps(state))
else:
    sys.exit(2)
''')
        self.regctl.chmod(0o700)
        self.env = os.environ | {
            "APP_DIR": str(self.root), "SYNC_RECORDS_DIR": str(self.records),
            "RUN_LOGS_DIR": str(self.root / "logs"), "ENTRY_SCRIPT": str(self.root / "entry.sh"),
            "REGCTL_BIN": str(self.regctl), "FAKE_LOG": str(self.log),
            "FAKE_STATE": str(self.root / "state.json"), "FAKE_FAIL": "0",
            "FROM_REGISTRY": "home.test", "MIRROR_TARGET": "cn.test",
            "DOCKER_USERNAME": "fixture", "DOCKER_PASSWORD": "fixture-only",
            "CN_DOCKER_USERNAME": "fixture", "CN_DOCKER_PASSWORD": "fixture-only",
            "MAX_ATTEMPTS": "1", "RETRY_BASE_SECONDS": "0", "POST_COPY_SETTLE_SECONDS": "0",
            "PUBLIC_CHECK_INTERVAL_SECONDS": "27000", "INTERNAL_CHECK_INTERVAL_SECONDS": "27000",
        }

    def run_script(self, name, *args):
        return subprocess.run([str(self.root / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def seed_recent(self):
        digest = "sha256:" + "a" * 64
        (self.records / "aiursoft__dms_latest").write_text(f"{int(time.time())} {digest}\n")
        (self.root / "state.json").write_text(json.dumps({"cn.test/aiursoft/dms:latest": digest}))

    def test_force_checks_only_requested_image_despite_recent_record(self):
        self.seed_recent()
        result = self.run_script("force-update.sh", "aiursoft/dms:latest")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        digests = [a[2] for a in self.calls() if a[:2] == ["image", "digest"]]
        self.assertIn("home.test/aiursoft/dms:latest", digests)
        self.assertEqual(set(digests), {"home.test/aiursoft/dms:latest", "cn.test/aiursoft/dms:latest"})
        self.assertFalse(any(a[:2] == ["image", "copy"] for a in self.calls()))

    def test_force_copies_single_image_and_verifies_pinned_digest(self):
        result = self.run_script("force-update.sh", "aiursoft/dms:latest")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        copies = [a for a in self.calls() if a[:2] == ["image", "copy"]]
        self.assertEqual(copies, [["image", "copy", "home.test/aiursoft/dms@sha256:" + "a" * 64,
                                  "cn.test/aiursoft/dms:latest", "--digest-tags"]])
        self.assertIn("Service deployment must be checked separately", result.stdout)

    def test_force_normalizes_missing_tag(self):
        result = self.run_script("force-update.sh", "aiursoft/dms")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        copies = [a for a in self.calls() if a[:2] == ["image", "copy"]]
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0][3], "cn.test/aiursoft/dms:latest")

    def test_filtered_entry_keeps_quiet_period_without_force(self):
        self.seed_recent()
        result = self.run_script("entry.sh", "aiursoft/dms:latest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(["image", "digest", "home.test/aiursoft/dms:latest"], self.calls())
        self.assertIn("Skipped", result.stdout)

    def test_no_arguments_preserves_scheduled_inventory(self):
        result = self.run_script("entry.sh")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        copies = [a for a in self.calls() if a[:2] == ["image", "copy"]]
        self.assertEqual(len(copies), 15)
        self.assertIn("cn.test/aiursoft/wechatexam:latest", {a[3] for a in copies})
        self.assertNotIn("cn.test/aiursoft/dms:latest", {a[3] for a in copies})

    def test_invalid_arguments_never_login_or_create_records(self):
        for args in [(), ("a", "b"), ("--help",), ("aiursoft/dms;id",), ("aiursoft/*",), ("a" * 256,)]:
            with self.subTest(args=args):
                self.assertEqual(self.run_script("force-update.sh", *args).returncode, 78)
                self.assertEqual(self.calls(), [])

    def test_lock_is_shared_with_existing_cron(self):
        # start.sh's documented lock is held for its full entry/tee pipeline.
        with (self.records / "puller_cn.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("force-update.sh", "aiursoft/dms")
            self.assertEqual(result.returncode, 75)
            self.assertEqual(self.calls(), [])
            result = self.run_script("start.sh")
            self.assertEqual(result.returncode, 0)
            self.assertIn("another puller_cn run is active", result.stdout)
            self.assertEqual(self.calls(), [])
        self.assertEqual(self.run_script("force-update.sh", "aiursoft/dms").returncode, 0)

    def test_confirmed_sync_failure_is_70_and_releases_lock(self):
        self.env["FAKE_FAIL"] = "1"
        result = self.run_script("force-update.sh", "aiursoft/dms")
        self.assertEqual(result.returncode, 70)
        self.assertIn("exit code 1", result.stderr)
        self.env["FAKE_FAIL"] = "0"
        self.assertEqual(self.run_script("force-update.sh", "aiursoft/dms").returncode, 0)


if __name__ == "__main__":
    unittest.main()
