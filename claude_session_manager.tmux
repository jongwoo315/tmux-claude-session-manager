#!/usr/bin/env bash
# tmux-claude-session-manager
#
# List, monitor status, and jump across nested Claude Code sessions from a
# single popup. tpm runs this file as an executable on tmux startup; it reads
# user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @claude_launch_key 'y')"
new_key="$(get_tmux_option @claude_new_key 'Y')"
resume_key="$(get_tmux_option @claude_resume_key 'R')"
fork_key="$(get_tmux_option @claude_fork_key 'F')"
list_key="$(get_tmux_option @claude_list_key 'u')"
last_key="$(get_tmux_option @claude_last_key 'b')"
restart_key="$(get_tmux_option @claude_restart_key 'A')"

# Launch (or re-attach to) a Claude session for the current pane's directory.
# #{pane_current_path} / #{window_id} are expanded by run-shell before the args
# reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Launch a NEW session for the current pane's directory (multi-session per dir).
tmux bind-key "$new_key" \
  run-shell "$CURRENT_DIR/scripts/launch-new.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Launch a NEW picker-tracked session that resumes a past Claude conversation.
tmux bind-key "$resume_key" \
  run-shell "$CURRENT_DIR/scripts/resume-new.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Fork a past Claude conversation into a NEW picker-tracked session (fresh ID).
tmux bind-key "$fork_key" \
  run-shell "$CURRENT_DIR/scripts/fork-new.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Open the session picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh '#{q:client_name}'"

# Jump straight back to the last attached session (skip the picker).
tmux bind-key "$last_key" \
  run-shell "$CURRENT_DIR/scripts/last.sh"

# Restart every session with `claude --resume <id>` — for picking up a Claude
# CLI upgrade. Destructive and all-or-nothing, so it asks first and the script
# aborts on its own if any session is still working/waiting/bg. display-popup
# (not run-shell) so the abort list and the per-session result stay readable;
# it closes on any key.
# --pause keeps the popup open and prints its own centred prompt. Doing the wait
# inside the script avoids two earlier problems: the pause used to be a `read
# -rn1` in this command string, which is a bashism that tmux's zsh default-shell
# rejected (popup closed instantly, message unreadable), and the prompt was
# printed outside the script so it could not be centred with the message.
tmux bind-key "$restart_key" confirm-before \
  -p 'Restart ALL Claude sessions with --resume? (y/n)' \
  "display-popup -w 80% -h 60% -E \"'$CURRENT_DIR/scripts/restart-all.sh' --go --pause\""

# Track the most recently attached Claude session for the jump-back key. Append
# (-a) so a user's own client-attached hook is preserved.
tmux set-hook -ga client-attached \
  "run-shell \"$CURRENT_DIR/scripts/record-last.sh '#{q:client_session}'\""