FROM localhost:8080/box_starting/local_ubuntu
WORKDIR /app

# Set environment variables (critical for cron to work properly)
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# Install all dependencies in one layer
RUN apt-get update && \
    apt-get install -y cron python3 python-is-python3 python3-pip curl tini && \
    pip install requests && \
    rm -rf /var/lib/apt/lists/*

# Copy all scripts in one layer
COPY entry.sh start.sh source_updated.py /app/

# Avoid cache invalidation for stable layers above, download regctl with freshness check
#ADD "https://api.github.com/repos/regclient/regclient/commits?per_page=1" latest_commit
RUN curl -L https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64 -o /usr/local/bin/regctl && \
    chmod 755 /usr/local/bin/regctl

# Configure everything in one layer: permissions, logs, env, crontab
RUN chmod +x /app/entry.sh /app/start.sh && \
    mkdir -p /app/sync_records && \
    touch /var/log/puller-cron.log && \
    # Fix cron in Docker: pam_loginuid.so requires CAP_AUDIT_WRITE which
    # is unavailable in unprivileged containers / Swarm mode.  Without this
    # fix cron silently drops every scheduled job.
    sed -i '/pam_loginuid/s/required/optional/' /etc/pam.d/cron || true && \
    { \
        echo "LANG=C.UTF-8"; \
        echo "LC_ALL=C.UTF-8"; \
        echo "PIP_BREAK_SYSTEM_PACKAGES=1"; \
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
    } >> /etc/environment && \
    (crontab -l 2>/dev/null || true; echo "20 */8 * * * . /etc/environment; /app/start.sh > /proc/1/fd/1 2>/proc/1/fd/2") | crontab -

ENTRYPOINT ["tini", "--", "sh", "-c", "printenv | grep -v ' ' >> /etc/environment && cron -f -L 15"]