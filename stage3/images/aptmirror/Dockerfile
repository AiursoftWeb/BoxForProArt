FROM localhost:8080/public_mirror/aiursoft/static

RUN mkdir -p /data

COPY static-mirror-cleanup /etc/cron.d/static-mirror-cleanup

COPY cleanup.sh /usr/local/bin/cleanup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0644 /etc/cron.d/static-mirror-cleanup && \
    chmod +x /usr/local/bin/cleanup.sh && \
    chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]