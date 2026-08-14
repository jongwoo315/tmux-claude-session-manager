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
bg=0
if [ ! -t 0 ]; then
  raw=$(cat 2>/dev/null)
  # Event trace, enabled by `touch ~/.claude/state-debug` — for diagnosing missed
  # or misordered hook events (a state stuck against the picker's expectation).
  if [ -e "$HOME/.claude/state-debug" ]; then
    ev=$(printf '%s' "$raw" | /usr/bin/grep -oE '"hook_event_name":"[^"]*"' | head -1)
    printf '%s %s %s %s\n' "$(date +%H:%M:%S)" "$session" "$new" "${ev:-no-event}" >> "$HOME/.claude/state-debug.log"
  fi
  # Raw payload capture, enabled by `touch ~/.claude/state-debug-raw`. Stop events
  # only — the others fire far too often to keep. For checking what a hook actually
  # receives (e.g. whether background_tasks lists a running shell).
  if [ -e "$HOME/.claude/state-debug-raw" ]; then
    case "$raw" in *'"hook_event_name":"Stop"'*)
      printf '%s %s %s %s\n' "$(date +%H:%M:%S)" "$session" "$new" "$raw" \
        >> "$HOME/.claude/state-raw.log" ;;
    esac
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
  # A Stop fired while background agents are STILL RUNNING is not a real idle. The
  # foreground turn ended, but the session is visibly working ("Waiting for N
  # background agents to finish") and its agents keep producing tool events — which
  # the agent_id gate above correctly discards, so nothing would re-assert working.
  # Recording idle here also made orch read the debounced idle as step-complete and
  # close the task while the session was still working (observed: DEV-7133 marked
  # done mid-PR-review). Record WORKING instead. When the agents finish they
  # re-invoke the parent (UserPromptSubmit -> working), and THAT turn's Stop — with
  # no running entry in background_tasks — lands the real idle.
  #
  # Preserving the current state (the previous behaviour) left no way out for a
  # session that entered the agent episode already `waiting`: the agents' own tool
  # events die at the agent_id gate, the SubagentStop guard below refuses to clear
  # waiting, and this branch preserved it — so the picker showed yellow "waiting"
  # for a session whose screen read "Waiting for 2 background agents to finish",
  # until the user's next prompt. Observed 2026-08-05 on upgrade-impact-rag.
  # The cost is the mirror case: an AskUserQuestion box still up WHILE agents run
  # gets relabelled working. That needs the box and a live agent episode at once,
  # which is rarer than what this fixes.
  # skip_stamp for the same reason as SubagentStop above — one clock per episode.
  #
  # bg records WHY this is working, for the picker. The distinction it needs is
  # exactly the one this branch computes: the foreground turn is over (a Stop
  # really did fire) and only background work keeps the session busy. The picker
  # cross-checks `working` against tmux's repaint clock to catch ESC-interrupts,
  # which fire no hook at all — and a session parked here has also stopped
  # repainting, so that check cannot tell the two apart on its own and flapped
  # the row between working and idle every time a stray repaint landed.
  # @claude_state itself stays working: orch reads it and only understands
  # working|waiting|idle, and a Stop-set idle here would let it close a task
  # mid-flight (the whole reason this branch exists).
  case "$new:$raw" in idle:*'"status":"running"'*) new=working; skip_stamp=true; bg=1 ;; esac
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
# Written on every path that gets here, so it clears itself: the next foreground
# event (PostToolUse/UserPromptSubmit = working) or a real idle resets it to 0.
# The early exits above leave it alone, which is right — they change no state,
# and the picker only consults it for `working` rows.
tmux set-option -t "$session" @claude_bg "$bg"
[ "$new" != "$cur" ] && [ "$skip_stamp" = false ] &&
  tmux set-option -t "$session" @claude_state_at "$(date +%s)"
exit 0
