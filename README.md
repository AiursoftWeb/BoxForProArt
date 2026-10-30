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

The FRP client uses KCP on UDP port 7000. Verify that the separately managed
gateway's FRPS has `kcpBindPort = 7000` and allows UDP 7000 before deployment.
Keep its existing QUIC listener on UDP 9700 available as a fallback.

The transport change affects every proxy, including HTTP, HTTPS, GitLab SSH
and Minecraft. Existing per-proxy bandwidth limits, compression and PROXY
protocol settings are retained. After deployment, check these services,
complete transfers and interactive latency while the uplink is busy.
To return to QUIC, redeploy the client with `transport.protocol = "quic"`
and `serverPort = 9700` after verifying the gateway's QUIC listener.

## AgentBot model gateway

The GitLab stack runs AgentBot with Copilot CLI and the company OllamaGateway
provider at `https://ollama.aiursoft.com/v1`. Set `AGENT_BOT_API_KEY` in the
private deployment environment to the bot's Gateway API key.

The stack selects the virtual model `aiursoft-codex:latest`. Manage its physical
model mapping in OllamaGateway so model replacements do not require changing
AgentBot or this deployment. The declared client settings are:

| Setting | Value |
| --- | --- |
| Engine | `Copilot` |
| Reasoning effort | `xhigh` |
| Wire API | `responses` |
| Maximum prompt tokens | `922000` |
| Maximum output tokens | `128000` |
| Copilot offline mode | `true` |

AgentBot passes its configured endpoint, API key and virtual model to Copilot's
provider environment. This deployment uses provider authentication and requires
no interactive Codex or GitHub login. Only the workspace and logs are persisted;
there is no Codex credential mount to initialize.

GitLab issues still follow the planning and human approval workflow before
implementation. This configuration applies to AgentBot; the separate Happier
worker retains its native Codex setup described in
[Worker setup and recovery](stage4/stacks/happier/WORKER.md).
