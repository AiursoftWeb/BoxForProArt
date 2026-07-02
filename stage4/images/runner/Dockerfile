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
COPY . .

# Install regctl
RUN curl -m 50 -L https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64 -o /usr/local/bin/regctl && \
    chmod 755 /usr/local/bin/regctl

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# Apt tools and Node.js setup
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      nodejs \
      libgdiplus \
      build-essential \
      bc \
      ffmpeg \
      zip \
      unzip \
      tar \
      gcc \
      pkg-config \
      libglib2.0-dev \
      docker.io \
      docker-buildx \
      qemu-user-binfmt-hwe \
      gzip \
      iputils-ping \
      net-tools \
      git \
      jq \
      sudo \
      python3-pip \
      shellcheck \
      dotnet10 \
      gettext \
      wget \
      apt-utils \
      sassc \
      iproute2 \
      cargo \
      rustc \
      libgtk-4-dev \
      libadwaita-1-dev && \
        ln -sf /usr/bin/python3 /usr/local/bin/python && \
        ln -sf /usr/bin/pip3 /usr/local/bin/pip && \
    rm -rf /var/lib/apt/lists/*

# ARM64 cross-compilation toolchain for anduinos-deskmon, ufwall-gtk & anduinos-why-ai
RUN dpkg --add-architecture arm64 && \
    apt update && \
    apt install -y --no-install-recommends \
      gcc-aarch64-linux-gnu \
      libvulkan-dev:arm64 \
      libglib2.0-dev:arm64 \
      libgtk-4-dev:arm64 \
      libadwaita-1-dev:arm64 \
      libstd-rust-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*

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

# Install GitLab Runner
RUN curl -LJO "https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/latest/deb/gitlab-runner-helper-images.deb" && \
    curl -LJO "https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/latest/deb/gitlab-runner_amd64.deb" && \
    dpkg -i gitlab-runner-helper-images.deb && \
    dpkg -i gitlab-runner_amd64.deb && \
    rm -rf gitlab-runner-helper-images.deb gitlab-runner_amd64.deb

# Enable docker in docker & configure passwordless sudo
RUN usermod -aG docker root && \
    usermod -aG docker gitlab-runner && \
    usermod -aG sudo gitlab-runner && \
    echo "gitlab-runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Create a directory for data
RUN mkdir /data && chmod 777 /data && \
    chmod +x /app/entry.sh

# Inject Docker hijack script
COPY hijack_docker.sh /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker

ENTRYPOINT ["/bin/bash", "-c", "/app/entry.sh"]
