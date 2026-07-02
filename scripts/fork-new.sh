#!/usr/bin/env bash
# Fork a Claude conversation into a NEW picker-tracked session.
# Mirrors resume-new.sh naming (claude-<hash>[-N]) so it shows up in the picker,
# but runs `claude --resume --fork-session` — on first attach you pick which
# transcript to fork; the fork gets a fresh session ID so the original
# conversation stays untouched.
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
cmd="$(get_tmux_option @claude_fork_command 'claude --resume --fork-session --dangerously-skip-permissions')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# Don't spawn from inside a session popup.
if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

# First free name: claude-<hash>, then claude-<hash>-2, -3, ...
base="${prefix}$(session_hash "$path")"
session="$base"
n=2
while tmux has-session -t "$session" 2>/dev/null; do
  session="${base}-${n}"
  ((n++))
done

tmux new-session -d -s "$session" -c "$path" "$cmd"

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @claude_origin "$window"

# Default label so same-dir sessions are distinguishable in the picker.
tmux set-option -t "$session" @claude_title "${path##*/}#$((n - 1))~fork"

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"