FROM localhost:8080/box_starting/local_ubuntu:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends coreutils findutils util-linux && \
    rm -rf /var/lib/apt/lists/*

COPY clean.sh /usr/local/bin/runner-cleaner
RUN chmod 0755 /usr/local/bin/runner-cleaner

ENTRYPOINT ["/usr/local/bin/runner-cleaner"]
