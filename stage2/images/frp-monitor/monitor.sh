#!/bin/bash
# frp-monitor: watch frpc containers for "i/o deadline reached" and kill them if stuck.
# Scans last N lines of each container; if ≥THRESHOLD contain the pattern → kill.

TAIL_LINES=20
THRESHOLD=3
PATTERN="i/o deadline reached"
# Space-separated list of service names to watch, e.g. "frpc_ningbo"
SERVICE_NAMES="${SERVICE_NAMES:-frpc_ningbo}"
CHECK_INTERVAL=60

log() {
    echo "$(date -Iseconds) $1"
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
log "  pattern          : '$PATTERN'"
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
        CONTAINER_ID=$(docker ps --filter "name=${SVC}" --format "{{.ID}}" 2>/dev/null | head -1)
        if [ -z "$CONTAINER_ID" ]; then
            log "[$SVC] WARN: no running container, skip"
            continue
        fi
        log "[$SVC] container: $CONTAINER_ID"

        # Grab last N log lines
        LOGS=$(docker logs --tail "$TAIL_LINES" "$CONTAINER_ID" 2>&1)
        if [ -z "$LOGS" ]; then
            log "[$SVC] INFO: no logs yet, skip"
            continue
        fi

        # Count how many lines match the pattern
        MATCH_COUNT=$(echo "$LOGS" | grep -cF "$PATTERN" 2>/dev/null || true)
        log "[$SVC] deadline count: $MATCH_COUNT / $TAIL_LINES"

        if [ "$MATCH_COUNT" -ge "$THRESHOLD" ]; then
            log "[$SVC] ALERT: threshold reached ($MATCH_COUNT >= $THRESHOLD), killing $CONTAINER_ID"
            log "[$SVC] last $TAIL_LINES lines from $CONTAINER_ID:"
            echo "----------------------------------------"
            echo "$LOGS"
            echo "----------------------------------------"
            docker kill "$CONTAINER_ID" 2>&1
            log "[$SVC] docker kill sent to $CONTAINER_ID, Swarm will reschedule"
            log "[$SVC] sleeping 30s to let Swarm pull up new container..."
            sleep 30
            log "[$SVC] back from cooldown"
        else
            log "[$SVC] OK: $MATCH_COUNT < $THRESHOLD, no action"
        fi
    done
done