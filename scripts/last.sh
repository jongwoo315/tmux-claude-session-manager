#!/usr/bin/env bash
# Jump straight back into the last Claude session you were attached to, skipping
# the picker. Meant for the flow: detach a session (prefix+d), then this key to
# resume it. Falls back to the picker when there's no valid last session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# Don't nest a popup inside a session — detach first, then jump.
if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Detach first (prefix+d), then jump to last session'
  exit 0
fi

last="$(tmux show-option -gqv @claude_last_session)"

# No record yet, or the session was killed since — open the picker instead.
if [ -z "$last" ] || ! tmux has-session -t "$last" 2>/dev/null; then
  tmux display-message '⮐ No previous Claude session — opening picker'
  exec "$DIR/list.sh" "$(tmux display-message -p '#{client_name}')"
fi

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $last"
