# Private Happier relay

Single-user deployment at **https://happier.aiursoft.com**. The relay embeds the
WebUI and uses SQLite, local files and device-key accounts with E2EE. Public
signup is disabled. There is no OIDC or Authentik outpost in front of this service:
CLI/daemon API and Socket.IO connections use Happier's own authentication.

## Deployment

Point the domain through the existing Cloudflare/FRP ingress, like the other
sites. Do not cache the WebUI, API or Socket.IO endpoints at Cloudflare. Do not
publish container port 3005 on the host.

The stable image must be mirrored before deploying the stack. It is included in the
public puller's scheduled inventory. The puller also accepts an explicit list of
images. From the repository root on ProArt, send the updated script into the
existing puller to prefetch just this one, reusing its credentials and tools:

```bash
sudo docker ps --filter label=com.docker.swarm.service.name=puller_downloader \
  --format '{{.ID}}\t{{.Names}}'
sudo docker exec -i <puller-container-id> /bin/bash -s -- \
  happierdev/relay-server:stable \
  < stage3/images/puller/entry.sh
```

This does not require replacing the running puller first; stdin supplies the new
script even if the old image does not support image arguments. Wait for successful
mirroring before deploying the new stack. Do not run this manual copy while
another puller sync is active.

Then run the normal `sudo bash deploy.sh`. Stage 2 automatically includes
`happier.conf` in Caddy and discovers the domain alias. Stage 3 rebuilds the puller
with the updated inventory. Stage 4 automatically discovers this stack and
deploys `happier_relay`. No Happier-specific logic is needed in `deploy.sh`.

The data path is `/swarm-vol/ssd/happier/data`. The container's startup command
sets its top-level directory mode to 0700 and ownership to 1000:1000, then uses
`setpriv` to run the server as the official image's unprivileged user. The
light runtime generates its server master secret on first start and saves it at
`/data/handy-master-secret.txt`, backed by this directory. Keep that secret stable.

On a running installation, application-only redeploys can use:

```bash
sudo bash deploy.sh --stage 4 --filter happier
```

This skips rebuilding Caddy, so it is not sufficient to introduce or change the
public domain for the first time. Also, the existing stage4 runner/image setup
still runs before the filtered business-stack deployment.

## Create the only account (once)

The production service starts with registration closed even on an empty database.
Bootstrap through a temporary loopback-only container; never enable registration
on the public Swarm service.

On ProArt, stop the production task first. SQLite must have only one server:

```bash
sudo docker service scale happier_relay=0
sudo docker service ps happier_relay
```

Wait until no task is running, then start this foreground bootstrap container:

```bash
sudo docker run --rm --name happier-bootstrap \
  -p 127.0.0.1:3005:3005 \
  --user 1000:1000 \
  -e HAPPIER_SERVER_FLAVOR=light \
  -e HAPPIER_DB_PROVIDER=sqlite \
  -e HAPPIER_FILES_BACKEND=local \
  -e HAPPIER_SERVER_LIGHT_DATA_DIR=/data/happier \
  -e HAPPIER_PUBLIC_SERVER_URL=http://127.0.0.1:3005 \
  -e HAPPIER_WEBAPP_URL=http://127.0.0.1:3005 \
  -e HAPPIER_FEATURE_ENCRYPTION__STORAGE_POLICY=required_e2ee \
  -e AUTH_ANONYMOUS_SIGNUP_ENABLED=true \
  -v /swarm-vol/ssd/happier/data:/data \
  hub.aiursoft.com/happierdev/relay-server:stable
```

On your own computer, reach it through SSH:

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3005:127.0.0.1:3005 anduin@PROART_SSH_ADDRESS
```

Local port 3005 must be free: stop any old local POC relay first, or use a separate
local port and the corresponding browser URL. Open **http://127.0.0.1:3005**,
create your account, and back up its **Secret Key** in your password manager.
The account Secret Key is different from the server master secret.

Press Ctrl+C in the foreground bootstrap container's terminal to stop/remove it,
then bring back the production service:

```bash
sudo docker service scale happier_relay=1
```

Open **https://happier.aiursoft.com** and choose **Restore account / Secret Key**
to restore the same account. Do the same on additional browsers/devices. Closing
signup does not revoke pre-existing accounts; bootstrap only on a fresh database
or one whose accounts you already trust.

## Connect a computer running Codex

The relay does not execute Codex. Install the stable CLI on each
computer you want to control, then pair it with your existing browser account:

```bash
curl -fsSL https://happier.dev/install | bash
happier setup --relay https://happier.aiursoft.com
happier daemon install
happier status
```

Approve the computer in the browser where you restored the account. Complete
Codex's own login on that computer separately. The daemon must stay running for
the WebUI to launch sessions. Use the stable command `happier`; do not follow any
embedded WebUI instructions that suggest installing `hprev` or `hdev`. Server
updates do not update the CLI or daemon on connected computers.

Keep the relay limited to its own data volume: no Docker socket, source trees or
host Codex credentials. Choose the projects and permissions on the agent machine.

## Backup and upgrades

Back up the entire data directory, including the generated server master secret.
For a consistent SQLite backup, scale `happier_relay` to zero and wait for the
task to stop before copying, then scale it back to one. Back up the account Secret
Key separately. Losing it can prevent account recovery and E2EE decryption.

The service follows `hub.aiursoft.com/happierdev/relay-server:stable`. The public
puller checks the official `happierdev/relay-server:stable` tag on its normal
schedule and mirrors changes. The `shepherd.autoupdate=true` service label lets
the existing Shepherd update the relay after the mirror changes. Updates stay
single-replica and stop-first because SQLite and the data directory are shared.

Keep regular backups of the whole data directory before relying on automatic
updates. A binary rollback does not reverse database migrations; restoring an
older backup may be required. Keep connected CLIs on the stable channel as well,
and manage their updates separately.
