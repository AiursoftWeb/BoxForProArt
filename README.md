<a name="boxforproart-"></a>

# Aiursoft BoxForProart

## Overview

### What is BoxForProart?

**Role:** The Mothership (Core Compute & Storage)

This repository configures the **Core Node** located in the residential home lab, running on high-performance workstation hardware.

<a name="-strategic-objective"></a>

**Strategic objective.**

To provide massive compute power (GPU/CPU) and cheap storage (HDD) that would be prohibitively expensive in the cloud. It is the "Brain" and "Memory" of the system.

## Installation

Use a dedicated Linux host with systemd, Git, Bash and sudo access for this Box. The deployment entry point changes host configuration, installs or configures Docker, and deploys Docker Swarm services. Prepare the intended host, its storage and network access before running it.

Fetch the configuration repository:

```bash
git clone https://gitlab.aiursoft.com/aiursoft/boxforproart.git
cd boxforproart
```

Configure the private environment described in Configuration before deployment. This repository configures its named target; it is not a general-purpose installer for an unrelated workstation.

## Usage

<a name="-architecture-specifics"></a>

### Architecture

*   **Hardware:** ASUS ProArt Workstation (48G VRAM, 20TB Storage).
*   **Connectivity:**
    *   **Anycast FRP:** Connects to both `BoxForChina` and `BoxForGlobal` via Fast Reverse Proxy (FRP) tunnels.
    *   Traffic is routed intelligently: Domestic requests come via Ningbo, International via Poland.
*   **Data Sovereignty:** All master databases and Git repositories live here.

<a name="-stacks-included"></a>

### Stacks included

*   **Stage 2 (Network):**
    *   `frp`: The tunnel client connecting to public gateways.
*   **Stage 3 (Infrastructure):**
    *   `zot`, `nuget`, `npm`: Private internal registries for development artifacts.
*   **Stage 4 (Heavy Workloads):**
    *   `nupkg`, `nopkg`: S360-admitted NuGet and npm registries, with on-demand caching,
        direct home-network DNS and DNS-only public HTTPS through FRP.
    *   `s360`: Supply-chain dependency review at `https://s360.aiursoft.com`.
    *   `gitlab`: The full DevOps lifecycle platform.
    *   `clickhouse`: Analytics database.
    *   `nextcloud`: File storage and collaboration (20TB pool).
    *   `ocr`: PaddleOCR API service (optimized for CPU).
    *   `jellyfin`: Media streaming.
    *   `ai`: vLLM chat with DFlash2 and Ollama embeddings (leveraging the GPUs).
        See [AI startup and recovery](stage4/stacks/ai/VLLM_GUIDE.md).
    *   `runner`: GitLab CI/CD runners executing build jobs.
    *   `happier`: Private Codex/agent relay and embedded WebUI at
        `https://happier.aiursoft.com`, with E2EE and public registration disabled.
        See [Happier setup](stage4/stacks/happier/README.md) for the one-time
        account bootstrap, computer pairing and backups.
        Includes an always-on Codex worker based on the runner image,
        with a persistent `/home/anduin` and first-boot Happier pairing.
        See [Worker setup](stage4/stacks/happier/WORKER.md).

The list above describes the Box's service roles. The tracked `stage*/stacks` directories are the source of truth for the current deployable stack inventory.

### Deployment operations

Select a starting stage and, when needed, a stage-4 stack name filter:

```bash
sudo bash deploy.sh --stage 4 --filter shepherd
```

`--stage` runs the selected stage and all later stages. `--filter` matches a literal substring of stage-4 stack names. A stage-4 request with no matching stack fails before host preparation. From an earlier stage, an intentionally unmatched filter runs infrastructure and shared preparation only.

### FRP transport deployment

The FRP client uses KCP on UDP port 7000. Verify that the separately managed
gateway's FRPS has `kcpBindPort = 7000` and allows UDP 7000 before deployment.
Keep its existing QUIC listener on UDP 9700 available as a fallback.

The transport change affects every proxy, including HTTP, HTTPS, GitLab SSH
and Minecraft. Existing per-proxy bandwidth limits, compression and PROXY
protocol settings are retained. After deployment, check these services,
complete transfers and interactive latency while the uplink is busy.
To return to QUIC, redeploy the client with `transport.protocol = "quic"`
and `serverPort = 9700` after verifying the gateway's QUIC listener.

### AgentBot model gateway

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

### Approved CN Puller updates through DMS

After deploying the updated CN Puller and enrolling this Box's DMS Agent, use
`dms machine box puller force-update --puller cn --image aiursoft/dms:latest`
with the usual cluster, machine and reason options. The High-risk Lockbox freezes
the selected Puller and single-image/all-configured-images scope before approval. `--puller main` selects
the independent primary Puller.

CN's `/app/force-update.sh [IMAGE]` accepts one concrete image, or refreshes its
configured inventory when omitted. It shares cron's
persistent `puller_cn.lock`, and bypasses the quiet period for that invocation.
It calls the same digest-pinned, verified mirror logic as the scheduled job.
Without arguments, `entry.sh` retains its full scheduled inventory; with image
arguments it replaces that inventory with the explicit list. No cron, registry
credential or mirror configuration changes are required. Success means the
mirror is current; application deployment is checked separately.

Run the isolated CN tests with `python3 -m unittest discover -s tests -v`.
They execute the real scripts with a local registry-client substitute and need
neither Docker nor registry credentials/network access.

Omit `--image` to refresh all images configured in the selected Puller. DMS
shows `AllConfiguredImages` in the approval request. Refreshing all images does
not mean all machines: ambiguous machine selection still needs `--machine-id`
or an explicit `--all-machines`.

**Check the result.** On the target Swarm manager, inspect the selected stack and its tasks:

```bash
sudo docker stack ls
sudo docker stack services shepherd
sudo docker stack ps shepherd --no-trunc
```

Replace `shepherd` with the stack being inspected. Confirm the desired replicas, task errors and the service's own health endpoint or application behavior. A successful `docker stack deploy` submission does not prove every service is healthy. For a failed change, inspect task errors and restore a reviewed configuration through the same deployment entry point; preserve existing bind-mounted data.

## Configuration

`deploy.sh` reads `.env.prod` first and falls back to `.env`; it does not merge the two files. Keep real credentials in the private deployment environment. Values replace matching `{{VARIABLE_NAME}}` placeholders in memory before Docker receives the stack over standard input.

Prepare the private file from the tracked [.env](.env) reference and fill in the values required by the selected services:

```bash
cp .env .env.prod
$EDITOR .env.prod
```

`REGISTRY_HOST` and `REGISTRY_VERIFICATION_IMAGE` select the registry and the image used to verify access. `DOCKERHUB_USERNAME` and `DOCKERHUB_PASSWORD` are the deployment registry credentials. `PUBLIC_DOCKER_HUB_USERNAME` and `PUBLIC_DOCKER_HUB_PASSWORD` provide the separate public Docker Hub bootstrap credentials. The tracked environment reference also lists each application's OIDC, API, mail and other external settings. An absent environment file does not supply defaults for required registry credentials.

Service definitions and bind mounts live in `stage<N>/stacks/<stack-name>/docker-compose.yml`; custom image sources live in `stage<N>/images`. Review these files, the Caddy routes and any FRP configuration together before changing a service's exposure or storage. Keep existing database credentials and persistent data consistent during updates.

## Development

Validate the configuration using the repository's existing lint entry point:

```bash
bash -n deploy.sh
python3 ./lint.py
```

The linter requires Python 3 and PyYAML. The existing GitLab merge-request pipeline runs the repository's configured lint checks. Syntax and configuration checks do not deploy services or verify a live host.

<a name="-deployment"></a>

Use the supported deployment entry point for the intended target:

```bash
# On the ProArt Machine:
git clone https://gitlab.aiursoft.com/aiursoft/boxforproart.git
cd boxforproart
sudo bash deploy.sh
```

> **Note:** Ensure NVIDIA Drivers are installed for GPU passthrough support. The `deploy.sh` script will attempt to detect and configure them.

## How to contribute

There are many ways to contribute to the project: logging bugs, submitting pull requests, reporting issues, and creating suggestions.

Even if you have push rights on the repository, you should create a personal fork and create feature branches there when you need them. This keeps the main repository clean and your workflow cruft out of sight.

We're also interested in your feedback on the future of this project. You can submit a suggestion or feature request through the issue tracker. To make this process more effective, we're asking that these include more information to help define them more clearly.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
