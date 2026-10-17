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
    *   `s360`: Supply-chain dependency review at `https://s360.aiursoft.com`.
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

## FRP transport deployment

The FRP client uses QUIC on UDP port 9700. Before deploying this client,
configure the gateway's FRPS with the top-level setting `quicBindPort = 9700`
and allow UDP 9700 through its firewall. Keep the existing TCP/KCP listeners
on port 7000 available for rollback. The gateway configuration is managed
separately from this repository; verify its configuration source and apply
the server change first during a maintenance window.

The transport change affects every proxy, including HTTP, HTTPS, GitLab SSH
and Minecraft. Existing per-proxy bandwidth limits, compression and PROXY
protocol settings are retained. After deployment, check these services,
complete transfers and interactive latency while the uplink is busy.
To roll back, redeploy the client with `transport.protocol = "kcp"` and
`serverPort = 7000`, keeping the original KCP listener available.

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
