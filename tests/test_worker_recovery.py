from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


RECOVER = Path(__file__).resolve().parents[1] / 'stage4/images/worker/recover.sh'


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.script = self.home / 'worker-recover'
        self.script.write_bytes(RECOVER.read_bytes())
        self.script.chmod(0o755)
        self.profile = 'relay-fixture'
        self.recovery = self.home / '.worker/recovery' / self.profile
        self.server_dir = self.home / '.happier/servers' / self.profile
        self.server_dir.mkdir(parents=True)
        self.markers = self.home / '.happier/tmp/daemon-sessions'
        self.markers.mkdir(parents=True)
        (self.home / '.happier/settings.json').write_text(json.dumps({'activeServerId': self.profile}))
        self.state = self.server_dir / 'daemon.state.json'
        self.state.write_text(json.dumps({'machineId': 'own-machine'}))

    def run_script(self, command):
        env = {**os.environ, 'HOME': str(self.home)}
        result = subprocess.run(['bash', str(self.script), command], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def marker(self, agent, session, machine='own-machine'):
        workspace = self.home / 'workspace' / session
        workspace.mkdir(parents=True)
        data = {
            'startedBy': 'daemon', 'happySessionId': session,
            'metadata': {'machineId': machine, 'flavor': agent},
            'cwd': str(workspace),
            'respawn': {
                'version': 1, 'directory': str(workspace),
                'backendTarget': {'kind': 'builtInAgent', 'agentId': agent},
                'vendorResumeId': 'vendor-' + session,
                'profileId': 'saved-dgx-profile',
                'environmentVariables': {'COPILOT_HOME': '/home/anduin/.copilot-cici-super'},
                'codexBackendMode': 'appServer', 'spawnNonce': 'old-spawn',
                'pendingFirstInput': {'text': 'must-not-replay'},
                'initialPrompt': 'must-not-replay', 'prompt': 'must-not-replay',
                'message': 'must-not-replay', 'terminal': {'mode': 'old'}
            }
        }
        (self.markers / f'pid-{session}.json').write_text(json.dumps(data))
        return data

    def test_snapshot_includes_copilot_and_codex_but_excludes_other_sessions(self):
        self.marker('codex', 'codex-session')
        self.marker('copilot', 'copilot-session')
        self.marker('copilot', 'other-machine', machine='another-machine')
        self.marker('agy', 'unsupported-session')
        self.run_script('snapshot')
        self.assertEqual({p.name for p in self.recovery.glob('*.json')},
                         {'codex-session.json', 'copilot-session.json'})
        self.assertEqual((self.recovery / 'copilot-session.json').stat().st_mode & 0o777, 0o600)

    def test_restore_preserves_profile_and_resolves_copilot_identity_without_replaying_prompt(self):
        self.marker('copilot', 'copilot-session')
        self.marker('codex', 'codex-session')
        self.run_script('snapshot')
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                if self.headers.get('x-happier-daemon-token') != 'fixture-control-token':
                    self.send_error(401)
                    return
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path == '/ping':
                    body = {}
                elif self.path == '/spawn-session':
                    requests.append(data)
                    body = {'success': True, 'sessionId': data['existingSessionId']}
                else:
                    self.send_error(404)
                    return
                payload = json.dumps(body).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.state.write_text(json.dumps({'machineId': 'own-machine',
                                             'httpPort': server.server_port,
                                             'controlToken': 'fixture-control-token'}))
            self.run_script('restore')
            self.run_script('restore')
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(len(requests), 2, 'Already restored sessions must not be spawned twice')
        by_agent = {item['backendTarget']['agentId']: item for item in requests}
        for agent, item in by_agent.items():
            self.assertEqual(item['existingSessionId'], agent + '-session')
            self.assertEqual(item['profileId'], 'saved-dgx-profile')
            self.assertEqual(item['environmentVariables']['COPILOT_HOME'], '/home/anduin/.copilot-cici-super')
            self.assertFalse(item['approvedNewDirectoryCreation'])
            for field in ['vendorResumeId', 'spawnNonce', 'pendingFirstInput',
                          'initialPrompt', 'prompt', 'message', 'terminal']:
                self.assertNotIn(field, item)
        self.assertEqual(by_agent['codex']['codexBackendMode'], 'appServer')
        self.assertEqual(by_agent['codex']['resume'], 'vendor-codex-session')
        self.assertNotIn('codexBackendMode', by_agent['copilot'])
        self.assertNotIn('resume', by_agent['copilot'])

    def test_prepare_checkpoints_before_removing_stale_daemon_state(self):
        self.marker('copilot', 'copilot-session')
        self.run_script('prepare')
        self.assertTrue((self.recovery / 'copilot-session.json').exists())
        self.assertFalse(self.state.exists())

    def test_missing_workspace_stays_pending(self):
        self.marker('copilot', 'copilot-session')
        self.run_script('snapshot')
        (self.home / 'workspace/copilot-session').rmdir()
        self.assertIn('missing workspace', self.run_script('restore'))
        record = json.loads((self.recovery / 'copilot-session.json').read_text())
        self.assertEqual(record['workerRecoveryState'], 'pending')


if __name__ == '__main__':
    unittest.main()
