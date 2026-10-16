# BoxForProart 🏠

**Role:** The Mothership (Core Compute & Storage)

This repository configures the **Core Node** located in the residential home lab, running on high-performance workstation hardware.

## 🎯 Strategic Objective
To provide massive compute power (GPU/CPU) and cheap storage (HDD) that would be prohibitively expensive in the cloud. It is the "Brain" and "Memory" of the system.

## 🏗 Architecture Specifics
*   **Hardware:** ASUS ProArt Workstation (48G VRAM, 20TB Storage).
*   **Connectivity:**
    *   **Anycast FRP:** Connects to both `BoxForChina` and `BoxForGlobal` via Fast Reverse Proxy (FRP) tunnels.
    *   Traffic is routed intelligently: Domestic requests come via Ningbo, International via Poland.
*   **Data Sovereignty:** All master databases and Git repositories live here.

## 📦 Stacks Included
*   **Stage 2 (Network):**
    *   `frp`: The tunnel client connecting to public gateways.
*   **Stage 3 (Infrastructure):**
    *   `zot`, `nuget`, `npm`: Private internal registries for development artifacts.
*   **Stage 4 (Heavy Workloads):**
    *   `s360`: Staff dependency requests and review Web pilot at
        `https://s360.aiursoft.com`; see [S360 setup](#s360-web-pilot).
    *   `gitlab`: The full DevOps lifecycle platform.
    *   `clickhouse`: Analytics database.
    *   `nextcloud`: File storage and collaboration (20TB pool).
    *   `ocr`: PaddleOCR API service (optimized for CPU).
    *   `jellyfin`: Media streaming.
    *   `ai`: LLM and Stable Diffusion inference services (leveraging the GPUs).
    *   `runner`: GitLab CI/CD runners executing build jobs.
    *   `happier`: Private Codex/agent relay and embedded WebUI at
        `https://happier.aiursoft.com`, with E2EE and public registration disabled.
        See [Happier setup](stage4/stacks/happier/README.md) for the one-time
        account bootstrap, computer pairing and backups.
        Includes an always-on Codex worker based on the runner image,
        with a persistent `/home/anduin` and first-boot Happier pairing.
        See [Worker setup](stage4/stacks/happier/WORKER.md).

## 🚀 Deployment

```bash
# On the ProArt Machine:
git clone https://gitlab.aiursoft.cn/aiursoft/bash-app.git
cd bash-app/Boxes/BoxForProart
sudo bash deploy.sh
```

> **Note:** Ensure NVIDIA Drivers are installed for GPU passthrough support. The `deploy.sh` script will attempt to detect and configure them.

## AgentBot Codex authentication

The GitLab stack runs AgentBot with the `gpt-5.6-sol` Codex model and persists its ChatGPT login under `/swarm-vol/agent-bot/codex-home`. After the first deployment, find the active Swarm task:

```bash
sudo docker ps \
  --filter label=com.docker.swarm.service.name=gitlab_agent-bot \
  --format '{{.ID}}\t{{.Names}}'
```

Use the returned container ID to complete the one-time device login and verify it:

```bash
sudo docker exec -it --user bot <container-id> \
  codex login -c cli_auth_credentials_store=file --device-auth

sudo docker exec --user bot <container-id> \
  codex login -c cli_auth_credentials_store=file status
```

Codex stores and refreshes its credentials at `/home/bot/.codex/auth.json`, backed by the host directory above. Treat that directory like a secret. To switch AgentBot back to Claude, change `AgentBot__Engine` to `Claude` and restore `AgentBot__Model=aiursoft-super:latest`; the existing API key and endpoint are deliberately kept in the stack configuration.

## S360 Web pilot

The `stage4/stacks/s360` stack follows the existing AiurDrive/GitMirror layout:
OIDC in the application, a dedicated MySQL database on the stack's `internal`
overlay, shared `proxy_app` ingress and `clickhouse_net` logging, and three
persistent volumes. Application updates use the standard 20s/start-first/5s
policy; MySQL uses 60s/stop-first/60s. The application has a 4 CPU/4 GiB limit
like GitMirror, and MySQL has the usual 2 CPU/4 GiB limit. Keep one application
replica for the initial pilot and its scheduled resolution/audit jobs.

Before the first deployment:

1. Create an Authentik OIDC application/provider for S360, restricted to staff,
   with callback `https://s360.aiursoft.com/signin-oidc` and authority
   `https://auth.aiursoft.com/application/o/s360`. Provide the standard `groups`
   claim. The `Employees` default role permits requests; map the `Administrators`
   role only to the designated reviewers. Group-derived roles are synchronized
   on sign-in, so configure reviewer access in the identity provider.
2. Add `S360_CLIENT_ID`, `S360_CLIENT_SECRET` and `S360_MYSQL_PASSWORD` to the
   existing private `.env.prod` (or `.env`) used by `deploy.sh`. Use a dedicated
   database password; do not commit any values. Changing this password later
   also requires updating the existing MySQL account, not just its container
   environment. Do not deploy with unresolved `{{...}}` placeholders.
3. Prepare `/swarm-vol/ssd/s360-data/aspnet`,
   `/swarm-vol/ssd/s360-data/files` and `/swarm-vol/ssd/s360-data/mysql`
   through the normal volume preparation step. Back up the database, files and
   Data Protection keys together. Resolution caches stay in the application's
   own temporary container filesystem; monitor available space during the pilot.
4. Point `s360.aiursoft.com` through the existing Cloudflare/FRP ingress and
   rebuild Stage 2's sites image/domain aliases using the normal deployment
   workflow. The new `.conf` and stack are discovered automatically. No new
   host port, FRP tunnel or special case in `deploy.sh` is needed.

Stage 4 alone (`sudo bash deploy.sh --stage 4 --filter s360`) does not prepare
new volume directories or rebuild the ingress, and still runs the existing
Stage 4 image/runner setup before filtering business stacks. Use it only after
those prerequisites have been completed.

This stage enables the Web workflow only. `SupplyChain__CheckApiKey` stays empty,
so the CI check credential cannot authenticate; no Runner installation or
project pipeline enforcement is included. The permitted package sources are the
existing NuGet/npm mirrors. The existing SDK/Node-enabled S360 image supplies the
resolver tools; this does not change or validate APKG runtime dependencies.

S360 restores untrusted package metadata and archives. This stack grants no
Docker socket, host workspace, registry push credentials or unrelated application
volumes. It follows the existing shared application networks; these networks and
resource limits are **not an egress sandbox**. Review resolver network isolation
before promoting the pilot to an approval authority or enabling CI enforcement.
Do not use the pilot as proof that a dependency is safe to install.

For pilot acceptance, verify `/health`, the real OIDC login and staff/reviewer
permissions, a package request with its transitive graph and a review decision,
then confirm data survives an application restart. Verify that missing/invalid
check credentials are rejected. Check vulnerability audit success and temporary
space use before expanding the pilot. These runtime checks require a separately
approved deployment; repository lint and Compose validation do not establish them.

To roll back the pilot, remove only the `s360` stack and remove/rebuild its ingress
route through the normal workflow. Preserve its three data directories for
recovery; taking the service down must not delete the database or backups.
