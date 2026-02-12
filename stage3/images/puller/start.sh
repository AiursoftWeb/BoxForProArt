#!/bin/bash
# This script runs the entry.sh in a new tmux session
# Each execution creates a timestamped session name

SESSION_NAME="puller-$(date +%Y%m%d-%H%M%S)"

# Create a new detached tmux session and run entry.sh
tmux new-session -d -s "$SESSION_NAME" "/app/entry.sh"

# Log the session creation
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created tmux session: $SESSION_NAME" >> /var/log/puller-sessions.log
