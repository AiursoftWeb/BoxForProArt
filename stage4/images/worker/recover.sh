#!/usr/bin/env bash
# Keep the original Happier session ID; never replay a prompt or a shell command.
set -euo pipefail
umask 077
[ -r "$HOME/.happier/settings.json" ] || exit 0
profile=$(jq -er '.activeServerId' "$HOME/.happier/settings.json")
[[ "$profile" =~ ^[a-zA-Z0-9._-]+$ && "$profile" != . && "$profile" != .. ]]
state="$HOME/.happier/servers/$profile/daemon.state.json"
recovery="$HOME/.worker/recovery/$profile"
mkdir -p "$recovery"
shopt -s nullglob

if [ "${1:-}" = prepare ]; then
    "$0" snapshot
    # Only called at container startup, under entry.sh's exclusive home lock.
    # PIDs and the control port belonged to the previous container.
    rm -f "$state" "$state.lock"
    exit 0
fi

if [ "${1:-}" = snapshot ]; then
    machine=$(jq -r '.machineId // empty' "$state" 2>/dev/null || true)
    [ -n "$machine" ] || exit 0
    for marker in "$HOME"/.happier/tmp/daemon-sessions/pid-*.json; do
        # Other relay profiles and non-Codex sessions are not ours to restore.
        if ! jq -e --arg machine "$machine" '
            .startedBy == "daemon" and .metadata.machineId == $machine and
            (.respawn.backendTarget.agentId // .metadata.flavor) == "codex"
        ' "$marker" >/dev/null 2>&1; then continue; fi
        session=$(jq -er '.happySessionId' "$marker")
        [[ "$session" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        jq '. + {workerRecoveryState: "pending", workerRecoveryCapturedAt: now}' \
            "$marker" > "$recovery/$session.json.tmp"
        mv "$recovery/$session.json.tmp" "$recovery/$session.json"
        echo "Saved interrupted worker session: $session"
    done
    exit 0
fi
[ "${1:-}" = restore ] || { echo 'Usage: worker-recover snapshot|restore' >&2; exit 2; }

for record in "$recovery"/*.json; do
    [ "$(jq -r '.workerRecoveryState' "$record")" != restored ] || continue
    session=$(jq -er '.happySessionId' "$record")
    directory=$(jq -r '.respawn.directory // .cwd // empty' "$record")
    # A missing checkout must not silently become an empty replacement directory.
    if [ ! -d "$directory" ]; then
        echo "Session $session remains interrupted: missing workspace $directory"
        continue
    fi
    payload=$(jq '
        (.respawn // {}) + {
            directory: (.respawn.directory // .cwd),
            existingSessionId: .happySessionId,
            backendTarget: {kind: "builtInAgent", agentId: "codex"},
            codexBackendMode: (.respawn.codexBackendMode // "appServer"),
            approvedNewDirectoryCreation: false
        } |
        if .vendorResumeId then .resume = .vendorResumeId else . end |
        del(.version, .vendorResumeId, .spawnNonce, .terminal, .sessionId, .pendingFirstInput)
    ' "$record")
    restored=false
    for attempt in {1..12}; do
        port=$(jq -r '.httpPort // empty' "$state" 2>/dev/null || true)
        token=$(jq -r '.controlToken // empty' "$state" 2>/dev/null || true)
        if [[ "$port" =~ ^[0-9]+$ ]] && [ -n "$token" ] && \
            curl --noproxy '*' -fsS --max-time 3 -H "x-happier-daemon-token: $token" \
                -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$port/ping" >/dev/null 2>&1; then
            reply=$(curl --noproxy '*' -fsS --max-time 90 \
                -H "x-happier-daemon-token: $token" -H 'Content-Type: application/json' \
                --data-binary "$payload" "http://127.0.0.1:$port/spawn-session") || reply='{}'
            if jq -e --arg id "$session" '.success == true and .sessionId == $id' <<< "$reply" >/dev/null 2>&1; then
                jq '. + {workerRecoveryState: "restored", workerRecoveryRestoredAt: now}' \
                    "$record" > "$record.tmp"
                mv "$record.tmp" "$record"
                echo "Restored original worker session: $session (no commands replayed)"
                restored=true
                break
            fi
        fi
        sleep 5
    done
    if [ "$restored" = false ]; then
        echo "Session $session remains interrupted; history and recovery record retained. Retry: worker-recover restore"
    fi
done
