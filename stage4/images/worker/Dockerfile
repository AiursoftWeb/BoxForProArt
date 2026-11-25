FROM localhost:8080/box_starting/local_runner:latest

ARG HAPPIER_VERSION=0.2.21
ARG CODEX_VERSION=0.170.0
ARG COPILOT_VERSION=1.0.116
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs tini openssh-client && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g @happier-dev/cli@${HAPPIER_VERSION} @openai/codex@${CODEX_VERSION} --registry=https://registry.npmjs.org/ && \
    npm install -g --prefix /opt/worker-tools @github/copilot@${COPILOT_VERSION} --registry=https://registry.npmjs.org/ && \
    happier --version && codex --version && /opt/worker-tools/bin/copilot --version

# Ubuntu may already own UID 1000. Give that identity the worker's stable name.
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then \
      old_user="$(getent passwd 1000 | cut -d: -f1)"; \
      if [ "$old_user" != anduin ]; then usermod -l anduin "$old_user"; fi; \
      usermod -d /home/anduin -s /bin/bash anduin; \
    else useradd -u 1000 -m -s /bin/bash anduin; fi; \
    if ! getent group anduin >/dev/null; then groupadd anduin; fi; \
    usermod -g anduin anduin; \
    printf 'anduin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/anduin; \
    chmod 0440 /etc/sudoers.d/anduin; \
    install -d /opt/worker-home /home/anduin; \
    cp -a /etc/skel/. /opt/worker-home/; \
    cp -a /home/gitlab-runner/.cargo /home/gitlab-runner/.rustup /opt/worker-home/; \
    cp -a /root/.dotnet /opt/worker-home/; \
    install -d /opt/worker-home/.codex; \
    printf 'cli_auth_credentials_store = "file"\n[history]\npersistence = "save-all"\n' > /opt/worker-home/.codex/config.toml; \
    rm /usr/local/bin/docker

# Keep worker CLIs in the image so upgrades also reach existing persistent homes.
RUN curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/install-agy.sh && \
    bash /tmp/install-agy.sh --dir /opt/worker-tools && \
    /opt/worker-tools/agy --version && /opt/worker-tools/agy --help && \
    rm /tmp/install-agy.sh

RUN printf '%s\n' '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>' > /tmp/worker-nuget.config && \
    dotnet tool install Aiursoft.Kanban.Client --tool-path /opt/worker-tools --configfile /tmp/worker-nuget.config && \
    dotnet tool install Aiursoft.S360.Client --tool-path /opt/worker-tools --configfile /tmp/worker-nuget.config && \
    dotnet tool install Aiursoft.AlertCenter.Client --tool-path /opt/worker-tools --configfile /tmp/worker-nuget.config && \
    dotnet tool install Aiursoft.DMS.Client --tool-path /opt/worker-tools --configfile /tmp/worker-nuget.config && \
    /opt/worker-tools/kanban --help && \
    /opt/worker-tools/s360 --help && \
    /opt/worker-tools/alertcenter --help && \
    /opt/worker-tools/dms --help && \
    rm /tmp/worker-nuget.config

# Image tools precede home tools; preserve user-scoped tools and other home data.
ENV HOME=/home/anduin \
    PATH=/opt/worker-tools/bin:/opt/worker-tools:/home/anduin/.local/bin:/home/anduin/.cargo/bin:/home/anduin/.dotnet/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HAPPIER_SERVER_URL=https://happier.aiursoft.com \
    HAPPIER_WEBAPP_URL=https://happier.aiursoft.com \
    HAPPIER_PUBLIC_SERVER_URL=https://happier.aiursoft.com \
    HAPPIER_CLI_UPDATE_CHECK=0 \
    HAPPIER_COPILOT_PATH=/home/anduin/.local/bin/copilot-cici-super-happier \
    COPILOT_HOME=/home/anduin/.copilot-cici-super \
    COPILOT_OFFLINE=true \
    COPILOT_AUTO_UPDATE=false \
    COPILOT_PROVIDER_TYPE=openai \
    COPILOT_PROVIDER_BASE_URL=https://ollama.aiursoft.com/v1 \
    COPILOT_PROVIDER_WIRE_API=responses \
    COPILOT_PROVIDER_TRANSPORT=http \
    COPILOT_PROVIDER_VISION=true \
    COPILOT_PROVIDER_HEADERS="X-OllamaGateway-Responses-Compatibility: reasoning-summary" \
    COPILOT_PROVIDER_API_KEY_COMMAND="cat /home/anduin/.config/cici/ollama-api-key" \
    COPILOT_MODEL=aiursoft-super:latest \
    COPILOT_PROVIDER_MAX_PROMPT_TOKENS=491520 \
    COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=32768 \
    COPILOT_STRIP_REASONING_ON_RESUME=false \
    NO_PROXY=127.0.0.1,localhost,::1 \
    no_proxy=127.0.0.1,localhost,::1

COPY entry.sh /usr/local/bin/worker-entry
COPY health.py /usr/local/bin/worker-health
COPY recover.sh /usr/local/bin/worker-recover
RUN chmod 0755 /usr/local/bin/worker-entry /usr/local/bin/worker-health /usr/local/bin/worker-recover
WORKDIR /home/anduin
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/worker-entry"]
