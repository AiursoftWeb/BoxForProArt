FROM localhost:8080/box_starting/local_runner:latest

ARG HAPPIER_VERSION=0.2.16
ARG CODEX_VERSION=0.162.1
USER root
RUN apt-get update && apt-get install -y --no-install-recommends tini openssh-client && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g @happier-dev/cli@${HAPPIER_VERSION} @openai/codex@${CODEX_VERSION} && \
    happier --version && codex --version

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

# Seed user-scoped tools once into the persistent home, outside the mount at build time.
ENV HOME=/home/anduin \
    PATH=/home/anduin/.local/bin:/home/anduin/.cargo/bin:/home/anduin/.dotnet/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HAPPIER_SERVER_URL=https://happier.aiursoft.com \
    HAPPIER_WEBAPP_URL=https://happier.aiursoft.com \
    HAPPIER_PUBLIC_SERVER_URL=https://happier.aiursoft.com \
    HAPPIER_CLI_UPDATE_CHECK=0 \
    NO_PROXY=127.0.0.1,localhost,::1 \
    no_proxy=127.0.0.1,localhost,::1

COPY entry.sh /usr/local/bin/worker-entry
COPY health.py /usr/local/bin/worker-health
COPY recover.sh /usr/local/bin/worker-recover
RUN chmod 0755 /usr/local/bin/worker-entry /usr/local/bin/worker-health /usr/local/bin/worker-recover
WORKDIR /home/anduin
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/worker-entry"]
