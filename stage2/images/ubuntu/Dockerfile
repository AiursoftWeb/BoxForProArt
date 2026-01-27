FROM localhost:8080/public_mirror/ubuntu:25.10

COPY source.list /suggested.sources.list

RUN apt update && apt install -y curl ca-certificates apt-transport-https

RUN if curl -f https://ftp.uni-stuttgart.de; then \
        echo "Using ftp.uni-stuttgart.de" && \
        cp /suggested.sources.list /etc/apt/sources.list && \
        apt update; \
    fi

RUN rm /etc/apt/sources.list.d/ubuntu.sources || true
RUN apt modernize-sources -y && rm /etc/apt/sources.list.bak

RUN apt upgrade -y
