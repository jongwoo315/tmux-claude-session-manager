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
    case "$raw" in *'"agent_id":"'*)
      # 서브에이전트 이벤트는 부모 상태를 건드리지 않는다 — 단 하나 예외가 있다.
      #
      # 권한 프롬프트(Notification)로 걸린 waiting 은 사람이 답하면 사라지는데,
      # 그 답을 알려주는 이벤트가 따로 없다. 승인 뒤 이어지는 도구 호출이 그
      # 서브에이전트 것이면 여기서 전부 버려지고, 마지막 SubagentStop 마저 아래
      # 112번 가드가 막아서 세션이 waiting 에 갇힌다. 무인 orch 세션은 사용자
      # 프롬프트가 안 오므로 영영 안 풀린다 (실측 2026-09-03 claude-orch-95-search:
      # 00:39:44 Notification -> waiting, 00:40:13·00:41:00 PostToolUse 가 로그에만
      # 찍히고 상태는 그대로).
      #
      # 서브에이전트가 다시 도구를 쓴다는 것이 곧 프롬프트가 사라졌다는 증거다.
      # AskUserQuestion/ExitPlanMode 로 걸린 waiting 은 상자가 그대로 떠 있으므로
      # 여기서 풀면 안 된다 — 그래서 @claude_wait_src 로 출처를 갈라 둔다.
      #
      # tmux 호출이 하나 붙지만 서브에이전트 이벤트에만 든다. wait_src 는 waiting 을
      # 벗어날 때 지워지므로, 값이 비어 있지 않다는 것만으로 「지금 권한 대기 중」이
      # 판정돼 상태를 따로 읽지 않아도 된다.
      if [ -n "$(tmux display-message -p -t "$session" '#{@claude_wait_src}' 2>/dev/null)" ]; then
        tmux set-option -t "$session" @claude_state working
        tmux set-option -t "$session" @claude_bg 0
        tmux set-option -t "$session" @claude_state_at "$(date +%s)"
        tmux set-option -qu -t "$session" @claude_wait_src
      fi
      exit 0 ;;
    esac
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

# 한 번의 display-message 로 둘을 같이 읽는다 — show-options 두 번이면 포크가 둘이다.
IFS=' ' read -r cur wait_src <<EOF
$(tmux display-message -p -t "$session" '#{@claude_state} #{@claude_wait_src}' 2>/dev/null)
EOF

# SubagentStop must not clobber waiting: if the parent is blocked on
# AskUserQuestion/permission, an agent finishing doesn't unblock it — the box is
# still up. (UserPromptSubmit/PostToolUse working legitimately clear waiting.)
# 권한 프롬프트로 걸린 waiting 은 예외다 — 위 agent_id 게이트와 같은 이유로,
# 에이전트가 끝났다는 것은 승인이 났다는 뜻이다. AskUserQuestion 쪽은 그대로 막는다.
if [ "$subagent_stop" = true ] && [ "$cur" = "waiting" ]; then
  [ -z "$wait_src" ] && exit 0
fi

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
# waiting 의 출처. Notification 은 권한 프롬프트라 답하면 사라지고, PreToolUse
# (AskUserQuestion/ExitPlanMode)는 상자가 떠 있어 사용자 입력이 있어야 풀린다.
# 위 두 자리가 이 값으로 갈린다.
if [ "$new" = "waiting" ]; then
  case "$raw" in
    *'"hook_event_name":"Notification"'*) tmux set-option -t "$session" @claude_wait_src notification ;;
    *) tmux set-option -qu -t "$session" @claude_wait_src ;;
  esac
else
  tmux set-option -qu -t "$session" @claude_wait_src
fi
# Written on every path that gets here, so it clears itself: the next foreground
# event (PostToolUse/UserPromptSubmit = working) or a real idle resets it to 0.
# The early exits above leave it alone, which is right — they change no state,
# and the picker only consults it for `working` rows.
tmux set-option -t "$session" @claude_bg "$bg"
[ "$new" != "$cur" ] && [ "$skip_stamp" = false ] &&
  tmux set-option -t "$session" @claude_state_at "$(date +%s)"

# @claude_git — 브랜치 + 미커밋 파일 수(*N) + push 안 한 커밋 수(↑N).
#
# 여기서 재는 이유는 비용이다. picker 안에서 돌리면 목록을 그릴 때마다,
# ctrl-x reload마다 세션 수만큼 git이 뜬다(19개에 200ms 실측). 훅은 턴 경계에서만
# 도므로 턴당 1회고, picker는 @claude_state 읽듯 공짜로 읽는다.
#
# 브랜치만으로는 값이 얕다 — 워크트리 경로가 이미 브랜치 이름을 절반 담고 있다
# (~/prv/.wt/95-search → feat/95-search). *N·↑N은 경로에 없는 정보라서,
# 「세션은 끝났는데 커밋이 안 올라갔다」가 목록에서 바로 보인다.
gitdir="$(tmux display-message -pt "$session" '#{pane_current_path}' 2>/dev/null)"
if br="$(git -C "$gitdir" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  n="$(git -C "$gitdir" status --porcelain 2>/dev/null | grep -c '')"
  [ "$n" -gt 0 ] && br="$br *$n"
  # @{u} 는 upstream이 없으면 실패한다. 새로 낸 브랜치가 그렇고, 그때는 조용히 뺀다.
  a="$(git -C "$gitdir" rev-list --count '@{u}..HEAD' 2>/dev/null)"
  [ -n "$a" ] && [ "$a" -gt 0 ] && br="$br ↑$a"
  tmux set-option -t "$session" @claude_git "$br"

  # @claude_link — 워크트리면 메인 repo의 절대 경로, 메인이면 딸린 워크트리 수.
  # picker 가 경로를 그 repo 를 쥔 세션의 제목으로 바꿔 그린다. 세션 제목은 다른
  # 세션의 것이라 훅에서 못 만든다 — 훅은 자기 세션만 안다.
  #
  # --path-format=absolute 가 필요하다. 메인 워크트리 안에서 --git-common-dir 은
  # 상대 경로 ".git" 을 돌려주므로, 그대로 비교하면 메인이 워크트리로 오판된다.
  top="$(git -C "$gitdir" rev-parse --show-toplevel 2>/dev/null)"
  cmn="$(git -C "$gitdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  mainroot="${cmn%/.git}"
  if [ -n "$top" ] && [ "$top" != "$mainroot" ]; then
    tmux set-option -t "$session" @claude_link ">$mainroot"
  else
    w="$(git -C "$gitdir" worktree list 2>/dev/null | grep -c '')"
    if [ "${w:-0}" -gt 1 ]; then
      tmux set-option -t "$session" @claude_link "+$((w - 1))wt"
    else
      tmux set-option -t "$session" @claude_link "-"
    fi
  fi
else
  tmux set-option -t "$session" @claude_link "-"
  # 빈 문자열이 아니라 "-" 다. show-options 는 미설정과 빈 값을 똑같이 ""로 주므로,
  # 빈 값을 쓰면 picker 가 「아직 안 잰 세션」과 「repo 아닌 세션」을 구분하지 못해
  # 매번 다시 잰다.
  tmux set-option -t "$session" @claude_git "-"
fi
exit 0
