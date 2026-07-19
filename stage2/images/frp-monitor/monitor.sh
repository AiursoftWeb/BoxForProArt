#!/bin/bash
# frp-monitor: watch frpc for "i/o deadline reached" and kill it if stuck.
# Scans last N lines; if ≥THRESHOLD contain the pattern, the connection is dead → kill.

TAIL_LINES=20
THRESHOLD=3
PATTERN="i/o deadline reached"
SERVICE_NAME="frpc_ningbo"
CHECK_INTERVAL=60

log() {
    echo "$(date -Iseconds) $1"
}

if [ -z "$SERVICE_NAME" ]; then
    log "FATAL: No SERVICE_NAME provided."
    exit 1
fi

log "============================================"
log "frp-monitor started"
log "  watching service : $SERVICE_NAME"
log "  check interval   : ${CHECK_INTERVAL}s"
log "  tail lines       : $TAIL_LINES"
log "  threshold        : $THRESHOLD"
log "  pattern          : '$PATTERN'"
log "  action on alert  : docker kill <container>"
log "============================================"

TICK=0
while true; do
    sleep "$CHECK_INTERVAL"
    TICK=$((TICK + 1))

    log "--- tick #$TICK ---"

    # Find the running frpc container
    CONTAINER_ID=$(docker ps --filter "name=${SERVICE_NAME}" --format "{{.ID}}" 2>/dev/null | head -1)
    if [ -z "$CONTAINER_ID" ]; then
        log "WARN: no running container matching '${SERVICE_NAME}', skip this tick"
        continue
    fi
    log "target container: $CONTAINER_ID"

    # Grab last N log lines
    LOGS=$(docker logs --tail "$TAIL_LINES" "$CONTAINER_ID" 2>&1)
    if [ -z "$LOGS" ]; then
        log "INFO: no logs yet from $CONTAINER_ID, skip this tick"
        continue
    fi

    # Count how many lines match the pattern
    MATCH_COUNT=$(echo "$LOGS" | grep -cF "$PATTERN" 2>/dev/null || true)
    log "deadline count  : $MATCH_COUNT / $TAIL_LINES"

    if [ "$MATCH_COUNT" -ge "$THRESHOLD" ]; then
        log "ALERT: threshold reached ($MATCH_COUNT >= $THRESHOLD), killing $CONTAINER_ID"
        log "last $TAIL_LINES lines from $CONTAINER_ID:"
        echo "----------------------------------------"
        echo "$LOGS"
        echo "----------------------------------------"
        docker kill "$CONTAINER_ID" 2>&1
        log "docker kill sent to $CONTAINER_ID, Swarm will reschedule"
        log "sleeping 30s to let Swarm pull up new container..."
        sleep 30
        log "back from cooldown, resuming watch"
    else
        log "OK: $MATCH_COUNT < $THRESHOLD, no action"
    fi
done