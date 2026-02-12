FROM localhost:8080/box_starting/local_ubuntu
WORKDIR /app

# Install dependencies
RUN apt-get update && \
    apt install -y cron python3 python-is-python3 python3-pip curl tmux docker.io && \
    rm -rf /var/lib/apt/lists/*

ADD "https://api.github.com/repos/regclient/regclient/commits?per_page=1" latest_commit

RUN curl -L https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64 >regctl && \
    chmod 755 regctl && \
    mv regctl /usr/local/bin/

# Set environment variables (critical for cron to work properly)
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN pip install requests

# Copy scripts
COPY entry.sh /app/entry.sh
COPY start.sh /app/start.sh
COPY check.py /app/check.py
COPY delete.py /app/delete.py
COPY is_latest.py /app/is_latest.py
RUN chmod +x /app/entry.sh /app/start.sh

# Create log files
RUN touch /var/log/puller-cron.log /var/log/puller-sessions.log

# Export environment variables to /etc/environment for cron
RUN echo "LANG=C.UTF-8" >> /etc/environment && \
    echo "LC_ALL=C.UTF-8" >> /etc/environment && \
    echo "PIP_BREAK_SYSTEM_PACKAGES=1" >> /etc/environment && \
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> /etc/environment

# Register crontab job to run every hour at minute 20
# Each run creates a new tmux session with timestamp
RUN crontab -l 2>/dev/null | { cat; echo "20 * * * * . /etc/environment; /app/start.sh >> /var/log/puller-cron.log 2>&1"; } | crontab -

# Start cron in foreground with verbose logging
ENTRYPOINT ["cron", "-f", "-L 15"]