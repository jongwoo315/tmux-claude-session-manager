#!/usr/bin/env bash
# Toggle the last Claude session, skipping the picker:
#   - inside a session popup  -> close it (detach)
#   - on the outer client     -> reopen the last attached session
# One key both ways. Falls back to the picker when there's no valid last session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# Already inside a session popup -> close it. The client-attached hook already
# recorded this session, so the next press reopens it.
if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux detach-client
  exit 0
fi

last="$(tmux show-option -gqv @claude_last_session)"

# No record yet, or the session was killed since — open the picker instead.
if [ -z "$last" ] || ! tmux has-session -t "$last" 2>/dev/null; then
  tmux display-message '⮐ No previous Claude session — opening picker'
  exec "$DIR/list.sh" "$(tmux display-message -p '#{client_name}')"
fi

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $last"
