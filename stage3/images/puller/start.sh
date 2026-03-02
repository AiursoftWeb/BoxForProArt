#!/bin/bash
# This script runs entry.sh in a new tmux session.
# Sessions are kept alive after completion for debugging (tmux attach -t <session>).

# Guard: if entry.sh is still running from a previous cron trigger, skip this run.
# We check the process table, NOT tmux session names, so completed-but-kept sessions
# do not block the next scheduled run.
if pgrep -f "/app/entry.sh" > /dev/null 2>&1; then
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] entry.sh already running, skipping this cron trigger."
    echo "$MSG" | tee -a /var/log/puller-sessions.log
    exit 0
fi

SESSION_NAME="puller-$(date +%Y%m%d-%H%M%S)"

# Create a new detached tmux session and run entry.sh.
# remain-on-exit is set GLOBALLY before session creation to avoid a race condition
# where entry.sh finishes before remain-on-exit can be applied to the session.
# entry.sh is passed directly as the session command so it correctly inherits
# all environment variables from the current process.
tmux set-option -sg remain-on-exit on 2>/dev/null || true
tmux new-session -d -s "$SESSION_NAME" /app/entry.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created tmux session: $SESSION_NAME" >> /var/log/puller-sessions.log
