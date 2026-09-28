FROM localhost:8080/box_starting/local_ubuntu
ENV DEBIAN_FRONTEND=noninteractive

COPY source.list /suggested.sources.list
RUN apt update && apt install -y curl ca-certificates apt-transport-https && \
    cp /suggested.sources.list /etc/apt/sources.list && \
    apt update && \
    rm /etc/apt/sources.list.d/ubuntu.sources || true && \
    apt modernize-sources -y && rm /etc/apt/sources.list.bak && \
    apt upgrade -y

WORKDIR /app

# Install regctl
RUN curl --fail --show-error --location \
    --connect-timeout 20 --max-time 300 \
    --retry 5 --retry-delay 5 --retry-all-errors \
    https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64 \
    -o /usr/local/bin/regctl && \
    chmod 755 /usr/local/bin/regctl

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# Keep build and test dependencies in the runner image. Repository pipelines
# must not mutate the runner at job time with apt installs.
# Apt tools and Node.js setup
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      nodejs \
      libgdiplus \
      build-essential \
      bc \
      ffmpeg \
      aria2 \
      zip \
      unzip \
      tar \
      gcc \
      pkg-config \
      libglib2.0-dev \
      libgstreamer1.0-dev \
      libgstreamer-plugins-base1.0-dev \
      docker.io \
      docker-buildx \
      qemu-user-binfmt-hwe \
      gzip \
      iputils-ping \
      net-tools \
      git \
      gjs \
      jq \
      ripgrep \
      sudo \
      dbus-daemon \
      dconf-cli \
      fontconfig \
      gsettings-desktop-schemas \
      netplan.io \
      unattended-upgrades \
      pango1.0-tools \
      python3 \
      python3-gi \
      python3-cairo \
      python3-gi-cairo \
      python3-apt \
      gir1.2-gstreamer-1.0 \
      gir1.2-gtk-4.0 \
      gir1.2-adw-1 \
      gir1.2-nm-1.0 \
      libopencc1.1 \
      gir1.2-gst-plugins-base-1.0 \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad \
      python3-pip \
      python3-unidecode \
      shellcheck \
      grub2-common \
      dotnet10 \
      gettext \
      wget \
      apt-utils \
      dpkg \
      appstream \
      util-linux \
      librsvg2-bin \
      sassc \
      iproute2 \
      libgtk-4-dev \
      libpcap-dev \
      libvulkan-dev \
      libclang-dev \
      libclang-21-dev \
      cmake \
      glslc \
      spirv-headers \
      libadwaita-1-dev && \
        ln -sf /usr/bin/python3 /usr/local/bin/python && \
        ln -sf /usr/bin/pip3 /usr/local/bin/pip && \
    rm -rf /var/lib/apt/lists/*

# AnduinOS package source tests validate generated GRUB syntax without
# installing a bootloader or building a DEB inside the test job.
RUN grub-script-check --version

# ARM64 cross-compilation toolchain for Rust/GTK applications
# No libclang*-arm64 packages here — they conflict with the AMD64 versions
# needed by Rust bindgen (parse C headers at build time). ARM C cross-compilation
# and Rust cross-linking don't require target-arch libclang.
RUN dpkg --add-architecture arm64 && \
    apt update && \
    apt install -y --no-install-recommends \
      gcc-aarch64-linux-gnu \
      g++-aarch64-linux-gnu \
      libc6-dev-arm64-cross \
      libvulkan-dev:arm64 \
      libglib2.0-dev:arm64 \
      libgstreamer1.0-dev:arm64 \
      libgstreamer-plugins-base1.0-dev:arm64 \
      libgtk-4-dev:arm64 \
      libadwaita-1-dev:arm64 \
      libpcap-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*

# Rust voice builds need development metadata, not just runtime plugins/GIR.
# Check each architecture without letting the cross build use host .pc files.
RUN pkg-config --exists gio-2.0 gstreamer-1.0 gstreamer-app-1.0 && \
    PKG_CONFIG_PATH= \
    PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig \
    pkg-config --exists gio-2.0 gstreamer-1.0 gstreamer-app-1.0

# Python packages
RUN pip install PyYAML

# .NET Global Tools
RUN echo '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /><add key="Aiursoft" value="https://nuget.aiursoft.com/v3/index.json" /></packageSources></configuration>' > ./temp.config && \
    dotnet tool install JetBrains.ReSharper.GlobalTools --global --configfile ./temp.config -v d || echo 'JB already installed.' && \
    dotnet tool install dotnet-reportgenerator-globaltool --global --configfile ./temp.config -v d || echo 'ReportGenerator already installed.' && \
    dotnet tool install aiursoft.apkg.client --global --configfile ./temp.config -v d || echo 'apkg already installed.' && \
    rm ./temp.config

# Node.js Global Tools
RUN npm config set registry https://npm.aiursoft.com && \
    npm install -g typescript ts-node npm yarn --loglevel verbose

# Install GitLab Runner as a standalone binary. The runner is launched directly
# by entry.sh, so installing a systemd service inside this container is neither
# needed nor valid. Keep the version pinned for reproducible image builds.
ARG GITLAB_RUNNER_VERSION=v19.3.0
RUN --mount=type=cache,target=/var/cache/gitlab-runner-downloads \
    set -eux; \
    download_dir=/var/cache/gitlab-runner-downloads; \
    runner_binary="gitlab-runner-linux-amd64-${GITLAB_RUNNER_VERSION}"; \
    if [ ! -s "$download_dir/$runner_binary" ]; then \
      aria2c \
        --disable-ipv6=true \
        --continue=true \
        --max-connection-per-server=16 \
        --split=16 \
        --min-split-size=1M \
        --max-tries=20 \
        --retry-wait=5 \
        --connect-timeout=20 \
        --timeout=60 \
        --lowest-speed-limit=1K \
        --auto-file-renaming=false \
        --allow-overwrite=true \
        --dir="$download_dir" \
        --out="$runner_binary" \
        "https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-amd64"; \
    fi; \
    install -m 0755 "$download_dir/$runner_binary" /usr/local/bin/gitlab-runner; \
    ln -s /usr/local/bin/gitlab-runner /usr/local/bin/gitlab-ci-multi-runner; \
    useradd \
      --system \
      --shell /bin/bash \
      --comment 'GitLab Runner' \
      --create-home \
      --skel /dev/null \
      gitlab-runner; \
    install -d -m 0700 /etc/gitlab-runner; \
    gitlab-runner --version

# Install the one canonical Rust toolchain used by shell-executor jobs. The
# setup script also cross-links an AArch64 binary, so a broken image fails here.
COPY setup-rust-toolchain.sh /usr/local/sbin/setup-rust-toolchain
RUN chmod 0755 /usr/local/sbin/setup-rust-toolchain && \
    /usr/local/sbin/setup-rust-toolchain

# Match the docker group to the ProArt host without changing the host socket.
RUN groupmod --gid 120 docker && \
    usermod -aG docker root && \
    usermod -aG docker gitlab-runner && \
    usermod -aG sudo gitlab-runner && \
    echo "gitlab-runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Container-aware application tests persist Data Protection keys under /data.
# Shell-executor jobs run as gitlab-runner and cannot create this at filesystem root.
RUN install -d -m 0750 -o gitlab-runner -g gitlab-runner /data

COPY entry.sh /app/entry.sh
RUN chmod +x /app/entry.sh

# Inject Docker hijack script
COPY hijack_docker.sh /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker

ENTRYPOINT ["/bin/bash", "/app/entry.sh"]
