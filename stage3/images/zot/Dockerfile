# The version need to be updated regularly.
ARG ZOT_VERSION=v2.1.13
FROM localhost:8080/box_starting/local_ubuntu

ARG ZOT_VERSION
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/zot /config /data

# Check if git.aiursoft.com is accessible. If so, download from the mirror.
# Otherwise, download from the official GitHub releases.
RUN M_URL="https://git.aiursoft.com/PublicVault/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" && \
    G_URL="https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" && \
    \
    echo "--> Measuring latency..." && \
    # 1. 测速 (仅请求头部 --head)，超时设为2秒。如果连接失败，赋值 100 秒确保排在后面
    M_TIME=$(curl -s -o /dev/null -w "%{time_total}" --head --connect-timeout 2 "$M_URL" || echo "100") && \
    G_TIME=$(curl -s -o /dev/null -w "%{time_total}" --head --connect-timeout 2 "$G_URL" || echo "100") && \
    echo "--> Latency: Mirror=${M_TIME}s, GitHub=${G_TIME}s" && \
    \
    # 2. 排序：将 "时间 URL" 写入文件并按数字排序，提取出 URL 列表
    echo "$M_TIME $M_URL" > /tmp/urls.txt && \
    echo "$G_TIME $G_URL" >> /tmp/urls.txt && \
    SORTED_URLS=$(sort -n /tmp/urls.txt | awk '{print $2}') && \
    \
    # 3. 循环下载：如果 wget 返回非 0 (下载失败)，则 continue 继续下一个
    SUCCESS=0 && \
    for url in $SORTED_URLS; do \
        echo "--> Attempting download from: $url"; \
        if wget -O /usr/local/bin/zot "$url"; then \
            echo "--> Download successful!"; \
            SUCCESS=1; \
            break; \
        else \
            echo "--> Download failed (HTTP Error or Timeout). Switching to fallback..."; \
        fi; \
    done && \
    \
    # 4. 最终检查：如果所有地址都失败，则报错退出
    if [ $SUCCESS -eq 0 ]; then echo "--> Fatal: All download mirrors failed!"; exit 1; fi && \
    chmod +x /usr/local/bin/zot && \
    rm -f /tmp/urls.txt

COPY default-config.json /etc/zot/default-config.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]