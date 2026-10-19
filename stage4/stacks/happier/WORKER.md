# Always-on Happier worker

`happier_worker` runs Codex on ProArt, using the development tools from
`localhost:8080/box_starting/local_runner:latest`. In Happier it appears as
**proart-worker**. Your laptop can be off: the browser talks to the relay, which
talks to this worker. ProArt, its internet connection and the model provider must
remain available.

## Build and deploy

The normal `sudo bash deploy.sh` creates the bind directory, builds all stage4
images (runner before worker), and discovers the Happier stack automatically.
`deploy.sh` contains no worker-specific setup or pairing logic.

For the first deployment on an existing Box, run on ProArt from the repository:

```bash
cd /swarm-vol/boxforproart
sudo install -d -m 0700 /swarm-vol/ssd/worker/home
sudo bash deploy.sh --stage 4 --filter happier
```

The directory command is necessary when skipping stage0 on the first deployment.
The stage4 Bash build commands still build the other stage4 images; the filter
selects which stacks to deploy.

Images are built and pushed to the existing bootstrap registry; the public image
puller needs no new image entry. Worker inherits runner, and installs pinned
stable npm releases (`@happier-dev/cli` 0.2.16 and `@openai/codex` 0.162.1) while
building, using runner's npm registry configuration. No packages are downloaded
during normal container startup.

## Network

Relay and worker share the stack-scoped `happier_backend` overlay. The worker
connects directly to `http://relay:3005`; browser and pairing URLs remain
`https://happier.aiursoft.com`. Worker also joins `proxy_app` so Box site domains resolve to Caddy through
its generated network aliases, avoiding the host-published-port hairpin path.
Worker publishes no ports. The backend is not marked `internal: true`, because the worker needs
outbound access to model providers, Git remotes and package registries.

The existing home bind path is unchanged. If an earlier standalone `worker` stack
was deployed, stop/remove that stack before deploying this combined stack; never
run both against the same home. Its old public-URL relay profile is preserved,
but the internal relay URL may require approving the new profile once.

## First approval

Open your existing account at <https://happier.aiursoft.com>. Then inspect the
worker's logs on ProArt:

```bash
sudo docker service logs --tail 60 happier_worker
```

On a new home directory the worker prints a **private pairing link**. Open it in
your signed-in browser and approve the computer. Treat that link as private until
it expires. The worker claims the approval, saves its credentials and machine ID,
and starts `happier daemon start-sync` in the foreground. No terminal attachment,
systemd service inside the container, or account Secret Key in Compose is needed.
The token returned by `auth wait` is never printed to Docker logs.

Pairing requests expire and are retried. A relay outage preserves stored
credentials. Revoked credentials require approval again. A health status of
`healthy` while waiting for first approval means the bootstrap process is alive;
it does **not** mean the machine is already paired or Codex authenticated.

Find the current container ID for the remaining commands:

```bash
worker_id=$(sudo docker ps --filter label=com.docker.swarm.service.name=happier_worker --format '{{.ID}}' | head -n 1)
test -n "$worker_id"
sudo docker exec --user anduin "$worker_id" happier daemon status
```

The shell variable only lasts in the current shell. In a web command executor,
include the assignment and the command in the same invocation, separated by `;`,
or replace it with the actual container ID.

## Authenticate Codex once

Happier's machine pairing and ChatGPT authentication are separate. On ProArt:

```bash
sudo docker exec --user anduin "$worker_id" codex login --device-auth
```

Open the URL and enter the device code using your ChatGPT account, then check:

```bash
sudo docker exec --user anduin "$worker_id" codex login status
```

The seeded Codex config uses `cli_auth_credentials_store = "file"`, so the login
persists under `/home/anduin/.codex`. Existing configuration is not overwritten.
If your account disallows device login, use the provider authentication options
available to that account; there is no automatic reuse of laptop credentials.

From Happier choose **New session → proart-worker → Codex**, and select a project
under `/home/anduin/Source/Repos`. Clone your projects there and configure Git/SSH
as `anduin`, through Happier's terminal or `docker exec --user anduin`.
The worker does not need a published inbound port or a mounted host Docker socket.

## Storage and tools

Only one application volume is mounted:

```text
/swarm-vol/ssd/worker/home → /home/anduin
```

This stores projects, SSH/Git configuration, Happier identity and history,
Codex authentication/session files, and user tool caches. Back up this directory
separately from the Happier relay's data. Protect backups as credentials.
Happier's browser transcript also depends on the relay's persistent database;
the worker home alone is not a backup of that database.
Do not clone an enrolled home into two simultaneously running workers; each new
worker should receive a separate home and its own approval.

The entrypoint fixes the home's top-level ownership and initializes it once as
UID 1000 (`anduin`). Rust and .NET global tools installed for other users in runner
are seeded into the home on first boot; subsequent boots preserve user changes.
The seed lives at `/opt/worker-home` so the volume cannot hide it. Installed
user toolchains persist across image upgrades; update those explicitly when needed.

Kanban (`kanban`), S360 (`s360`) and AlertCenter (`alertcenter`) CLIs are installed
from the existing Aiursoft NuGet source into `/opt/worker-tools` during the image
build. This directory precedes home tools in `PATH`, so both new and existing
homes use the image-provided versions without overwriting home contents. These
CLIs require their own runtime credentials; none are included in the image.
APKG, ReSharper and ReportGenerator continue to use the inherited tool seed.

`anduin` has passwordless sudo **inside this container**. System packages installed
at runtime outside the home disappear when the container is replaced; add required
system packages to the Dockerfile. Docker CLI is inherited, but no Docker engine
or host socket is provided. Container builds need a separately configured engine.
Runner's host-specific Docker wrapper is removed in this derived image.

## Lifecycle and acceptance checks

Tini forwards stop signals to the entrypoint and reaps children. The entrypoint
checkpoints session recovery records before stopping the daemon. Swarm
restarts an exited task; updates use one replica and stop-first to avoid two
daemons sharing one home. An exclusive file lock also rejects a second worker
using the same home. Local health checks use authenticated HTTP directly on
127.0.0.1, bypassing proxies. Both proxy bypass variables explicitly include
`127.0.0.1`, avoiding the previously observed CIDR bypass failure.

Before relying on the worker while travelling:

1. Approve it and authenticate Codex; confirm **proart-worker** is online.
2. Create a session from your phone, request a harmless command, and receive its result.
3. Close all terminal windows; send another message and confirm it runs.
4. Finish the test task, then replace the container:

   ```bash
   sudo docker service update --force --detach=false happier_worker
   ```

5. Confirm the same machine identity returns, projects and authentication remain,
   and you can resume the old conversation from the web UI and create a new one.

At startup, `worker-recover` saves the previous daemon's Codex session markers
before Happier can clean them up. Recovery records live in
`/home/anduin/.worker/recovery/<relay-profile>/`. It then removes stale daemon
PID/port state: a PID reused by the new container must not block startup.
Credentials, machine identity and transcripts are preserved.

Once the daemon starts, the helper asks its authenticated local API to restore
each original Happier session ID and workspace. Codex resumes its stored thread.
It does not create replacement conversations or inject a continuation prompt.
Already queued user messages can run after restoration; otherwise send a message
to continue. This integration uses the local API and session markers of the pinned
Happier 0.2.16 CLI; repeat crash tests when upgrading it.

Missing workspaces or failed restores leave a pending recovery record and a log
message. The original conversation remains on the relay. After correcting the
problem, retry as the worker user:

```bash
sudo docker exec --user anduin "$worker_id" worker-recover restore
```

`TMPDIR` points into `/home/anduin/.cache/tmp` so tools that respect it retain
temporary working files. Files explicitly written outside the home (including
literal `/tmp` paths), process memory and unflushed writes are not guaranteed to
survive replacement. An interrupted shell process cannot continue at its exact
instruction; Codex must inspect saved progress and decide the next action. Never
assume an external operation did not complete just because its reply was lost.

### Tested on 2026-10-15

Isolated tests used real Happier 0.2.16 and Codex 0.162.1 binaries, a separate relay
and test account, and a deterministic local Responses endpoint. During an actual
Codex tool command that wrote a checkpoint and then slept, tests performed:

| Interruption | Result after removing and recreating the container |
| --- | --- |
| `docker kill` (SIGKILL) | Original machine/session/Codex rollout, credentials, memory and written progress retained; continued after a new message |
| `docker stop` (SIGTERM) | Same checks passed; entrypoint saved recovery records before stopping |

Tests also checked that previous message IDs remained and commands were not
automatically replayed. The test fixture mounted the same persistent home across
recreation and used a small Debian image with the actual worker scripts. It did
**not** build the full runner-derived image, deploy to ProArt, or test a real
ChatGPT connection. Run the image smoke check and phone acceptance steps there.

Worker updates are explicit deploys, with no Shepherd autoupdate label, to avoid
interrupting coding sessions on a scheduled image refresh. Bump the pinned CLI
versions in its Dockerfile and redeploy after finishing active tasks. Relay updates
do not update this worker's CLI. For image smoke checks on ProArt:

```bash
sudo docker run --rm --network none --tmpfs /home/anduin:rw,exec \
  localhost:8080/box_starting/local_worker:latest bash -ec \
  'id; node --version; python3 --version; dotnet --version; dotnet tool list --global; cargo --version; rustc --version; happier --version; codex --version'
```

This checks a fresh home without pairing or touching the enrolled worker volume.
Official references: [CLI and pairing](https://docs.happier.dev/apps/cli),
[daemon and headless login](https://docs.happier.dev/apps/daemon).
