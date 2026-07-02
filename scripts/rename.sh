#!/usr/bin/env bash
# Prompt for a new picker label and store it on the session as @claude_title.
# Called from the picker's ctrl-r binding: rename.sh <session-name>
set -uo pipefail
s="${1:?session name required}"

printf 'New label for %s (empty = clear): ' "$s" >/dev/tty
IFS= read -r title </dev/tty || exit 0

if [ -n "$title" ]; then
  tmux set-option -t "$s" @claude_title "$title"
else
  tmux set-option -u -t "$s" @claude_title  # unset -> picker falls back to dir name
fi
