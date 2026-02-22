FROM localhost:8080/box_starting/local_ubuntu
WORKDIR /app

# Set environment variables (critical for cron to work properly)
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# Install all dependencies and pip packages in one layer
RUN apt-get update && \
    apt-get install -y cron python3 python-is-python3 python3-pip curl tmux docker.io && \
    pip install requests && \
    rm -rf /var/lib/apt/lists/*

# Copy all scripts in one layer
COPY entry.sh start.sh check.py delete.py is_latest.py source_updated.py /app/

# Avoid cache invalidation for stable layers above, download regctl with freshness check
#ADD "https://api.github.com/repos/regclient/regclient/commits?per_page=1" latest_commit
RUN curl -L https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64 -o /usr/local/bin/regctl && \
    chmod 755 /usr/local/bin/regctl

# Configure everything in one layer: permissions, logs, env, crontab
RUN chmod +x /app/entry.sh /app/start.sh && \
    mkdir -p /app/sync_records && \
    touch /var/log/puller-cron.log /var/log/puller-sessions.log && \
    { \
        echo "LANG=C.UTF-8"; \
        echo "LC_ALL=C.UTF-8"; \
        echo "PIP_BREAK_SYSTEM_PACKAGES=1"; \
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
    } >> /etc/environment && \
    (crontab -l 2>/dev/null || true; echo "20 */8 * * * . /etc/environment; /app/start.sh >> /var/log/puller-cron.log 2>&1") | crontab -

ENTRYPOINT ["cron", "-f", "-L", "15"]