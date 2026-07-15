#!/usr/bin/env bash
# Count claude-* sessions whose @claude_state is 'waiting'; print a status-bar
# badge, or nothing when none are waiting. Wired into status-right (see README).
set -uo pipefail

n=$(tmux list-sessions -F '#{session_name} #{@claude_state}' 2>/dev/null \
      | awk '$2 == "waiting"' | wc -l | tr -d ' ')

[ "${n:-0}" -gt 0 ] && printf '#[fg=black]⏳ %s waiting #[default]' "$n"
exit 0
