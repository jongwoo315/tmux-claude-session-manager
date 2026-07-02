#!/usr/bin/env bash
# Launch a NEW picker-tracked session that RESUMES a past Claude conversation.
# Same naming scheme as launch-new.sh (claude-<hash>[-N]) so it shows up in the
# picker, but runs `claude --resume` — on first attach you pick which transcript
# to continue. Use this to bring a killed/quit session back under picker control
# (plain `claude --resume` in a normal window is invisible to the picker).
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
cmd="$(get_tmux_option @claude_resume_command 'claude --resume --dangerously-skip-permissions')"
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
# n-1 == the suffix used (1 for the base session, 2 for -2, ...).
tmux set-option -t "$session" @claude_title "${path##*/}#$((n - 1))~resume"

tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"
