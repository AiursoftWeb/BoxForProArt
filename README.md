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
    *   `gitlab`: The full DevOps lifecycle platform.
    *   `clickhouse`: Analytics database.
    *   `nextcloud`: File storage and collaboration (20TB pool).
    *   `ocr`: PaddleOCR API service (optimized for CPU).
    *   `jellyfin`: Media streaming.
    *   `ai`: LLM and Stable Diffusion inference services (leveraging the GPUs).
    *   `runner`: GitLab CI/CD runners executing build jobs.

## 🚀 Deployment

```bash
# On the ProArt Machine:
git clone https://gitlab.aiursoft.cn/aiursoft/bash-app.git
cd bash-app/Boxes/BoxForProart
sudo bash deploy.sh
```

> **Note:** Ensure NVIDIA Drivers are installed for GPU passthrough support. The `deploy.sh` script will attempt to detect and configure them.
