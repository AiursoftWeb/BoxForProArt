# The version need to be updated regularly.
ARG ZOT_VERSION=v2.1.20
ARG ZOT_SHA256=a32e42d042d1f17b5b1317e55cc1a415a744c873dcd05c25c56b665478258bcb
FROM localhost:8080/box_starting/local_ubuntu

ARG ZOT_VERSION
ARG ZOT_SHA256
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends aria2 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/zot /config /data

RUN ZOT_URL="https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
    && if ! aria2c \
        --allow-overwrite=true \
        --auto-file-renaming=false \
        --max-connection-per-server=16 \
        --split=16 \
        --min-split-size=1M \
        --dir=/usr/local/bin \
        --out=zot \
        "${ZOT_URL}"; then \
        rm -f /usr/local/bin/zot /usr/local/bin/zot.aria2; \
        curl --fail --location \
            --retry 20 \
            --retry-all-errors \
            --retry-delay 2 \
            --output /usr/local/bin/zot \
            "${ZOT_URL}"; \
    fi \
    && echo "${ZOT_SHA256}  /usr/local/bin/zot" | sha256sum -c - \
    && chmod +x /usr/local/bin/zot \
    && /usr/local/bin/zot --version 2>&1 | grep -q "\"commit\":\"${ZOT_VERSION}-"

COPY default-config.json /etc/zot/default-config.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
