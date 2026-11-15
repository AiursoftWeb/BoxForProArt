#!/bin/bash
# Restart frpc only when fresh timeouts persist and its proxies are not running.

TAIL_LINES=20
THRESHOLD=3
LOG_WINDOW=5m
# Space-separated list of service names to watch, e.g. "frpc_ningbo"
SERVICE_NAMES="${SERVICE_NAMES:-frpc_ningbo}"
CHECK_INTERVAL=60

log() {
    echo "$(date -Iseconds) $1"
}

# A successful reconnect supersedes earlier failures, even if they remain in the tail.
deadline_count() {
    awk '
        { gsub(/\033\[[0-9;]*m/, "") }
        /login to server success|start proxy success/ { count = 0; next }
        /i\/o deadline reached/ { count++ }
        END { print count + 0 }
    '
}

recent_logs() {
    docker logs --since "$LOG_WINDOW" --tail "$TAIL_LINES" "$CONTAINER_ID" 2>&1
}

if [ -z "$SERVICE_NAMES" ]; then
    log "FATAL: No SERVICE_NAMES provided."
    exit 1
fi

log "============================================"
log "frp-monitor started"
log "  watching services: $SERVICE_NAMES"
log "  check interval   : ${CHECK_INTERVAL}s"
log "  tail lines       : $TAIL_LINES"
log "  threshold        : $THRESHOLD"
log "  log window       : $LOG_WINDOW"
log "  action on alert  : docker kill <container>"
log "============================================"

TICK=0
while true; do
    sleep "$CHECK_INTERVAL"
    TICK=$((TICK + 1))

    log "--- tick #$TICK ---"

    for SVC in $SERVICE_NAMES; do
        log "[$SVC] checking..."

        # Find the running frpc container for this service
        CONTAINER_ID=$(docker ps --filter "name=${SVC}" --format "{{.ID}}" 2>/dev/null | sed -n '1p')
        if [ -z "$CONTAINER_ID" ]; then
            log "[$SVC] WARN: no running container, skip"
            continue
        fi
        log "[$SVC] container: $CONTAINER_ID"

        if ! LOGS=$(recent_logs); then
            log "[$SVC] WARN: cannot read logs, no action"
            continue
        fi
        MATCH_COUNT=$(printf '%s\n' "$LOGS" | deadline_count)
        log "[$SVC] unrecovered deadline count: $MATCH_COUNT / $TAIL_LINES"

        if [ "$MATCH_COUNT" -ge "$THRESHOLD" ]; then
            # Use the client's existing local admin API; do not infer health from logs alone.
            if ! STATUS=$(timeout 10s docker exec "$CONTAINER_ID" frpc status \
                -c /etc/frp/frpc.toml --api-timeout 5s 2>/dev/null); then
                log "[$SVC] WARN: cannot query proxy status, no action"
                continue
            fi
            printf '%s\n' "$STATUS" | awk '
                $1 == "Name" && $2 == "Status" { table = 1; next }
                table && NF >= 2 { proxies++; if ($2 != "running") unhealthy++ }
                END {
                    if (!proxies) exit 2
                    exit (unhealthy ? 1 : 0)
                }
            '
            PROXY_STATUS=$?
            if [ "$PROXY_STATUS" -eq 0 ]; then
                log "[$SVC] OK: proxies are running, no action"
                continue
            elif [ "$PROXY_STATUS" -ne 1 ]; then
                log "[$SVC] WARN: unrecognized proxy status, no action"
                continue
            fi

            # The client may have recovered while its status was being queried.
            if ! LOGS=$(recent_logs); then
                log "[$SVC] WARN: cannot recheck logs, no action"
                continue
            fi
            MATCH_COUNT=$(printf '%s\n' "$LOGS" | deadline_count)
            if [ "$MATCH_COUNT" -lt "$THRESHOLD" ]; then
                log "[$SVC] OK: recent recovery or expired failures, no action"
                continue
            fi
            log "[$SVC] ALERT: $MATCH_COUNT unrecovered deadlines and unhealthy proxies, killing $CONTAINER_ID"
            log "[$SVC] recent log tail from $CONTAINER_ID:"
            echo "----------------------------------------"
            echo "$LOGS"
            echo "----------------------------------------"
            if ! docker kill "$CONTAINER_ID"; then
                log "[$SVC] WARN: docker kill failed"
                continue
            fi
            log "[$SVC] docker kill sent to $CONTAINER_ID, Swarm will reschedule"
            log "[$SVC] sleeping 30s to let Swarm pull up new container..."
            sleep 30
            log "[$SVC] back from cooldown"
        else
            log "[$SVC] OK: $MATCH_COUNT < $THRESHOLD, no action"
        fi
    done
done
