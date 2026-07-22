#!/usr/bin/env bash
# Record a Claude Code session's state on its tmux session, for the picker.
# Wire this into Claude Code hooks (see README):  state.sh <working|waiting|idle>
#
# Claude Code hooks inherit the Claude process environment, so $TMUX_PANE is set
# whenever Claude runs inside tmux. Outside tmux this is a no-op.
#
# EXCEPT a forked/resumed session runs under a daemon on a background pty
# (`claude --fork-session --bg-pty-host`, parented by `claude daemon run`), whose
# env carries NO TMUX_PANE — so the hook can't find its tmux session and the
# picker state freezes at whatever the outer claude last set. Climb the parent
# pids for an ancestor that DOES have TMUX_PANE (the outer claude still owns the
# pane), and use that. Bounded to a few hops; only runs when TMUX_PANE is unset.
if [ -z "$TMUX_PANE" ]; then
  p=$PPID
  while [ "${p:-0}" -gt 1 ]; do
    tp=$(ps eww -p "$p" 2>/dev/null | tr ' ' '\n' | grep -m1 '^TMUX_PANE=')
    [ -n "$tp" ] && { TMUX_PANE="${tp#TMUX_PANE=}"; break; }
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
fi
[ -z "$TMUX_PANE" ] && exit 0

session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
[ -z "$session" ] && exit 0

new="${1:-idle}"

# Picker state tracks the FOREGROUND turn only. A background agent's tool events
# fire this same hook on the PARENT session (identical session_id and TMUX_PANE),
# so a session sitting idle at the prompt with lingering agents would get stamped
# working on every agent tool completion — frozen red after the answer landed.
# Subagent events carry a non-null "agent_id"; foreground events have it null or
# absent. Ignore the subagent ones. Only read stdin when piped (a hook) so a
# manual `state.sh idle` on a TTY doesn't block on cat ([ -t 0 ] true = terminal).
subagent_stop=false
skip_stamp=false
if [ ! -t 0 ]; then
  raw=$(cat 2>/dev/null)
  # Event trace, enabled by `touch ~/.claude/state-debug` — for diagnosing missed
  # or misordered hook events (a state stuck against the picker's expectation).
  if [ -e "$HOME/.claude/state-debug" ]; then
    ev=$(printf '%s' "$raw" | /usr/bin/grep -oE '"hook_event_name":"[^"]*"' | head -1)
    printf '%s %s %s %s\n' "$(date +%H:%M:%S)" "$session" "$new" "${ev:-no-event}" >> "$HOME/.claude/state-debug.log"
  fi
  # EXCEPT SubagentStop: a finished background agent re-invokes the PARENT loop
  # (it synthesizes the result with no prompt and often no tool call), so no
  # working-stamping hook would otherwise fire — the picker sat on the Stop-set
  # idle while the session was visibly working. SubagentStop IS the re-invoke
  # signal; let it through (as `working`) despite its agent_id.
  case "$raw" in *'"hook_event_name":"SubagentStop"'*) subagent_stop=true ;; esac
  if [ "$subagent_stop" = false ]; then
    case "$raw" in *'"agent_id":"'*) exit 0 ;; esac
  fi
  # A session with live agents BOUNCES idle<->working every agent-notification
  # cycle (Stop -> idle, SubagentStop -> working). Each bounce is a transition, so
  # stamping it pinned the picker age at 0m through an hours-long working stretch.
  # Treat the agent episode as ONE clock: skip the restamp on the transient hops —
  # Stop while agents still run, and the SubagentStop re-entry. The stamp then
  # survives from the episode's UserPromptSubmit until a real idle (Stop with no
  # running agents) or the user's next prompt.
  [ "$subagent_stop" = true ] && skip_stamp=true
  case "$new:$raw" in idle:*'"status":"running"'*) skip_stamp=true ;; esac
fi

cur=$(tmux show-options -qv -t "$session" @claude_state 2>/dev/null)

# SubagentStop must not clobber waiting: if the parent is blocked on
# AskUserQuestion/permission, an agent finishing doesn't unblock it — the box is
# still up. (UserPromptSubmit/PostToolUse working legitimately clear waiting.)
[ "$subagent_stop" = true ] && [ "$cur" = "waiting" ] && exit 0

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
[ "$new" != "$cur" ] && [ "$skip_stamp" = false ] &&
  tmux set-option -t "$session" @claude_state_at "$(date +%s)"
exit 0
