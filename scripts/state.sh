#!/usr/bin/env bash
# Record a Claude Code session's state on its tmux session, for the picker.
# Wire this into Claude Code hooks (see README):  state.sh <working|waiting|idle>
#
# Claude Code hooks inherit the Claude process environment, so $TMUX_PANE is set
# whenever Claude runs inside tmux. Outside tmux this is a no-op.
[ -z "$TMUX_PANE" ] && exit 0

session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
[ -z "$session" ] && exit 0

new="${1:-idle}"

# The Stop hook fires idle when the foreground turn ends — but a session with a
# live background agent is still working, not idle. Downgrading to idle makes the
# picker show idle for the whole (minutes-long) agent run. Stop passes the payload
# on stdin with background_tasks[]; if any is running, stay working. Only read
# stdin when it's piped (a hook) — a manual `state.sh idle` on a TTY must not block
# on cat. [ -t 0 ] is true for a terminal, false for a pipe.
if [ "$new" = "idle" ] && [ ! -t 0 ]; then
  raw=$(cat 2>/dev/null)
  running=$(printf '%s' "$raw" \
    | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)
  [ "${running:-0}" -gt 0 ] && new="working"
fi

cur=$(tmux show-options -qv -t "$session" @claude_state 2>/dev/null)

# Don't let a Stop-fired idle clobber waiting. AskUserQuestion/ExitPlanMode set
# waiting via PreToolUse; a session blocked on user input is NOT idle. Only the
# user moves it forward — their next prompt (UserPromptSubmit=working) or the
# tool's completion (PostToolUse=working). ESC-cancel leaves it waiting until the
# next prompt, a harmless cosmetic lag that self-heals.
[ "$new" = "idle" ] && [ "$cur" = "waiting" ] && exit 0

# Stamp @claude_state_at only on a real state TRANSITION. Otherwise a working
# session's clock resets every tool completion (PostToolUse=working re-asserts the
# same state), so the picker age never counts up. Same-state re-assert keeps the
# original timestamp → age reflects time since the state actually began.
tmux set-option -t "$session" @claude_state "$new"
[ "$new" != "$cur" ] && tmux set-option -t "$session" @claude_state_at "$(date +%s)"
exit 0
