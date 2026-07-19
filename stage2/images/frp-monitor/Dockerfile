# =============================
#        RUNTIME
# =============================
FROM localhost:8080/box_starting/local_ubuntu AS runtime

# Install docker CLI only (no daemon needed, just the client to talk to /var/run/docker.sock)
RUN apt update && apt install -y docker.io

COPY ./monitor.sh /
RUN chmod +x /monitor.sh

ENTRYPOINT [ "sh", "-c", "/monitor.sh" ]