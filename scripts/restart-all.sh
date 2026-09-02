#!/usr/bin/env bash
# Restart EVERY picker-tracked Claude session, resuming each one's transcript.
# Use after a Claude CLI upgrade: running processes keep the old binary, so only
# a restart picks up the new one.
#
#   restart-all.sh          show what would happen, change nothing
#   restart-all.sh --go     do it
#
# Refuses to run while ANY session is working / waiting / bg — including orch
# sessions. This is all-or-nothing on purpose: killing a pane mid-turn loses
# whatever that turn had not yet flushed to the transcript, and --resume replays
# only what was written. Wait for the session to settle, then run again.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

go=false
pause=false
for a in "$@"; do
  case "$a" in
    --go) go=true ;;
    # Hold the popup open until a key is pressed. Lives here rather than in the
    # key binding so the prompt can be centred with the rest of the message —
    # the binding has no idea how wide the popup is.
    --pause) pause=true ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done

# Centre a block of text in the popup. The abort screens are the whole content
# of an 80%x60% popup, and hugging the top-left corner of that much empty space
# reads as a rendering glitch rather than a message. Progressive output (the
# per-session ticks) is left flush — it is a list, not a message.
center_block() {
  local text cols lines n pad_top i
  text="$(cat)"
  # `stty size` reads the pty directly. tput needs a correct TERM and silently
  # falls back to 24x80 without it, which put the block a third of the way down
  # a 50-row popup instead of centring it.
  # …and it must read /dev/tty, not stdin: stdin here is the pipe carrying the
  # message, so a bare `stty size` sees a pipe and reports nothing.
  # Guard the open: without a controlling tty (a hook or cron run) bash itself
  # prints "/dev/tty: Device not configured" before stty's 2>/dev/null applies,
  # and that noise is now permanent in the log.
  read -r lines cols < <({ [ -r /dev/tty ] && stty size < /dev/tty; } 2>/dev/null || echo '')
  [ -n "${lines:-}" ] || lines="$(tput lines 2>/dev/null || echo 24)"
  [ -n "${cols:-}" ]  || cols="$(tput cols  2>/dev/null || echo 80)"
  n="$(printf '%s\n' "$text" | wc -l | tr -d ' ')"
  # Leave room for the "[any key to close]" prompt hold_open adds.
  pad_top=$(( (lines - n - 2) / 2 )); [ "$pad_top" -lt 0 ] && pad_top=0
  for ((i = 0; i < pad_top; i++)); do printf '\n'; done
  # Centre each line on its own, not the block as a whole. Block-centring left
  # every line flush to a common left edge, so short lines (a one-item session
  # list) looked stranded far left while the closing prompt — centred per line —
  # sat somewhere else entirely. Indentation is dropped for the same reason: it
  # only means anything against a shared left edge.
  printf '%s\n' "$text" | while IFS= read -r l; do
    center_line "$l"
  done
}

# Terminal width, resolved once. center_line runs per output line, and a
# stty+awk pair per line is a fork storm for no gain — the popup cannot resize
# mid-message.
TERM_COLS=''
term_cols() {
  [ -n "$TERM_COLS" ] && { printf '%s' "$TERM_COLS"; return; }
  read -r _ TERM_COLS < <({ [ -r /dev/tty ] && stty size < /dev/tty; } 2>/dev/null || echo '')
  [ -n "$TERM_COLS" ] || TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
  printf '%s' "$TERM_COLS"
}

# Centre one line horizontally. Leading/trailing space is stripped first: it was
# indentation relative to a left edge that no longer exists once every line is
# centred independently.
center_line() {
  local text cols w
  text="${1#"${1%%[![:space:]]*}"}"   # strip leading blanks
  text="${text%"${text##*[![:space:]]}"}"  # strip trailing blanks
  [ -n "$text" ] || { printf '\n'; return; }
  cols="$(term_cols)"
  # Width in characters with ANSI stripped, so colour codes and the emoji do not
  # skew the padding. awk counts characters under a UTF-8 locale.
  w="$(printf '%s' "$text" | sed $'s/\033\\[[0-9;]*m//g' |
       LC_ALL=en_US.UTF-8 awk '{ print length($0) }')"
  printf '%*s%s\n' "$(( (cols - w) / 2 < 0 ? 0 : (cols - w) / 2 ))" '' "$text"
}

# Everything below goes to a log as well as the popup. The popup's pty is
# destroyed the moment it closes, so the ✓/✗ lines are unrecoverable a second
# later — which is exactly why the 08-13 wipe had to be diagnosed backwards from
# file mtimes. Dry runs are logged too: the aborted dry run 30s before that wipe
# turned out to be the useful piece of evidence.
# Not under ~/.claude — that is a public git repo and these lines carry
# directory paths and session labels.
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-claude-session-manager"
log="$cache_dir/restart.log"
if mkdir -p "$cache_dir" 2>/dev/null && : >> "$log" 2>/dev/null; then
  chmod 600 "$log" 2>/dev/null
  # Trim before appending so the file cannot grow without bound.
  if [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
  fi
  printf '\n===== %s  restart-all.sh %s =====\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${*:-<no args: dry run>}" >> "$log"
  # tee's own stdout is the popup, captured before this redirect takes effect.
  exec > >(tee -a "$log") 2>&1
fi

hold_open() {
  [ "$pause" = true ] || return 0
  printf '\n'
  center_line '[any key to close]'
  [ -r /dev/tty ] && read -rsn1 < /dev/tty
}
trap hold_open EXIT

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
resume_cmd="$(get_tmux_option @claude_resume_command 'claude --resume --dangerously-skip-permissions')"
launch_cmd="$(get_tmux_option @claude_command 'claude --dangerously-skip-permissions')"

# `tmux display-message -p '#S'` is NOT a reliable "am I inside a session popup"
# test: run from a display-popup it resolves against whichever pane/client tmux
# picks, which is why the first version of this guard let the key binding through
# from inside a Claude popup and restarted the very session the user was sitting
# in. Scan the clients instead — same approach as list.sh::nested_session.
attached="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
  awk -v p="$prefix" 'index($2, p) == 1 { print $2 }' | sort -u)"
if [ -n "$attached" ]; then
  { printf '⛔ Aborted — a client is attached to a Claude session:\n\n'
    printf '  %s\n' $attached
    printf '\nThat session is about to be killed. Close the popup (or detach)\n'
    printf 'and run this from a plain tmux window.\n'
  } | center_block
  exit 1
fi

# --list is the picker's own snapshot: 2=session 3=state 5=title 6=git 7=cwd 8=sessionId.
# Re-delimit with US (0x1f) before parsing. TAB is an IFS *whitespace* character,
# so `IFS=$'\t' read` collapses runs of tabs: a session with no transcript has an
# empty sessionId, the empty field disappears, and every later field shifts one
# slot left — sid then holds the pane-preview text. That fed `claude --resume
# '⏸ pane preview off …'`, which dies on start, and the recreate abort took the
# session with it. US is not IFS whitespace, so empty fields are preserved.
rows="$("$DIR/picker.sh" --list 2>/dev/null | tr '\t' '\037')"
[ -n "$rows" ] || { printf 'No Claude sessions found.\n'; exit 0; }

plan=''    # session \t cwd \t sid \t title \t origin
busy=''
total=0
while IFS=$'\037' read -r _rank session state _age title _git cwd sid _prompt _n; do
  [ -n "$session" ] || continue
  total=$((total + 1))
  # state carries ANSI colour and a status glyph; keep the word only.
  st="$(printf '%s' "$state" | sed $'s/\033\\[[0-9;]*m//g' | tr -d ' ●○◐◌')"
  case "$st" in
    working|waiting|bg) busy+="  $session — $st"$'\n' ;;
  esac
  # Field 6 is tilde-abbreviated for display; ask tmux for the real path.
  real="$(tmux display-message -pt "$session" '#{pane_current_path}' 2>/dev/null)"
  [ -n "$real" ] || real="${cwd/#\~/$HOME}"
  origin="$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)"
  plan+="$session"$'\037'"$real"$'\037'"$sid"$'\037'"$(printf '%s' "$title" | sed 's/ *$//')"$'\037'"$origin"$'\n'
done <<< "$rows"

# Hard gate. Nothing is killed unless every session is settled.
if [ -n "$busy" ]; then
  { printf '⛔ Aborted — %s session(s) still active:\n\n' "$(printf '%s' "$busy" | grep -c .)"
    printf '%s' "$busy"
    printf '\nRestarting one mid-turn loses the unflushed part of that turn.\n'
    printf 'Wait for them to finish, then run again.\n'
  } | center_block
  exit 1
fi

printf '=== %s session(s) — all settled ===\n' "$total"
while IFS=$'\037' read -r s p sid t _o; do
  [ -n "$s" ] || continue
  printf '  %-38s %-26s %s\n' "$s" "${t:-—}" "${sid:-<no transcript — fresh start>}"
done <<< "$plan"

if [ "$go" = false ]; then
  printf '\nDry run. Re-run with --go to apply.\n'
  exit 0
fi

# Snapshot the plan to disk BEFORE the first kill. Session name, title and
# origin live only in the tmux server's memory: once a session is killed they
# are gone, and if the recreate does not land there is nothing left to rebuild
# from — only the transcript on disk, which knows neither the label nor the
# window it was launched from. Not in ~/.claude: that is a public git repo and
# these rows carry directory paths and session labels.
mkdir -p "$cache_dir" 2>/dev/null
snap="$cache_dir/restart-plan.tsv"
if printf '%s' "$plan" | tr '\037' '\t' > "$snap.tmp" 2>/dev/null && mv "$snap.tmp" "$snap" 2>/dev/null; then
  chmod 600 "$snap" 2>/dev/null
  printf '\nPlan saved to %s\n' "$snap"
else
  { printf '⛔ Aborted — could not write the recovery snapshot to\n'
    printf '%s\n\n' "$snap"
    printf 'Without it a failed recreate loses the session labels for good.\n'
  } | center_block
  exit 1
fi

printf '\n'
fail=0
aborted=''
while IFS=$'\037' read -r session path sid title origin; do
  [ -n "$session" ] || continue
  # Stop killing the moment a recreate fails. The old behaviour carried on
  # down the list, so one broken recreate cost every remaining session too.
  if [ -n "$aborted" ]; then
    printf '  · %s — left running (aborted)\n' "$session"
    continue
  fi
  # Reuse the user's configured command verbatim so wrappers survive (their
  # resume command is `printf '\033[5 q'; exec claude --resume …`, so the binary
  # is NOT the first word — splitting on whitespace would break it).
  # Only a real UUID may reach --resume. Anything else means the row was
  # mis-parsed; a fresh start loses history but keeps the session alive, which
  # beats killing it and failing to bring it back.
  case "$sid" in
    ????????-????-????-????-????????????) : ;;
    ?*) printf '  ! %s — ignoring malformed session id, starting fresh\n' "$session" >&2; sid='' ;;
  esac
  if [ -n "$sid" ]; then
    if [[ "$resume_cmd" == *" --resume"* ]]; then
      cmd="${resume_cmd/ --resume/ --resume $sid}"
    else
      cmd="$resume_cmd --resume $sid"
    fi
  else
    cmd="$launch_cmd"
  fi
  # A directory that no longer exists makes new-session fail *after* the kill,
  # so check before doing anything destructive.
  if [ ! -d "$path" ]; then
    printf '  ✗ %s — cwd is gone: %s (not touched)\n' "$session" "$path" >&2
    fail=$((fail + 1)); aborted="$session"
    continue
  fi

  tmux kill-session -t "=$session" 2>/dev/null
  # Recreate, verify it actually landed, retry once. `new-session` exiting 0 is
  # not proof, and neither is an immediate has-session: a command that dies on
  # start still leaves the session visible for about a second before tmux reaps
  # it. Settle first, then ask.
  ok=false
  for attempt in 1 2; do
    tmux new-session -d -s "$session" -c "$path" "$cmd" 2>/dev/null
    sleep "$(get_tmux_option @claude_restart_settle 2)"
    if tmux has-session -t "=$session" 2>/dev/null; then ok=true; break; fi
    [ "$attempt" = 1 ] && printf '  ↻ %s — died on start, retrying\n' "$session"
  done

  if [ "$ok" = true ]; then
    [ -n "$origin" ] && tmux set-option -t "$session" @claude_origin "$origin"
    [ -n "$title" ]  && tmux set-option -t "$session" @claude_title "$title"
    printf '  ✓ %s\n' "$session"
  else
    printf '  ✗ %s — failed to recreate (twice) — stopping here\n' "$session" >&2
    fail=$((fail + 1)); aborted="$session"
  fi
done <<< "$plan"

printf '\n%s restarted, %s failed.\n' "$((total - fail))" "$fail"

if [ -n "$aborted" ]; then
  { printf '\n⛔ Stopped at %s. Sessions below it were left alone.\n\n' "$aborted"
    printf 'Rebuild anything missing from the snapshot:\n'
    printf '  %s\n' "$snap"
    printf '(columns: session, cwd, sessionId, title, origin)\n'
  } | center_block
  exit 1
fi

# Claude needs a few seconds to boot and replay the transcript; a pane opened
# before that is blank, which reads as a broken session in the picker. Wait for
# each pane to paint something before saying we are done.
wait_secs="$(get_tmux_option @claude_restart_wait 60)"
printf '\nWaiting for panes to render (up to %ss)…\n' "$wait_secs"
pending=''
while IFS=$'\037' read -r s _p _sid _t _o; do
  [ -n "$s" ] && pending+="$s"$'\n'
done <<< "$plan"

for _ in $(seq "$wait_secs"); do
  still=''
  while read -r s; do
    [ -n "$s" ] || continue
    if tmux capture-pane -pt "$s" 2>/dev/null | grep -q '[^[:space:]]'; then
      printf '  ✓ %s\n' "$s"
    else
      still+="$s"$'\n'
    fi
  done <<< "$pending"
  pending="$still"
  [ -z "${pending//[$'\n' ]/}" ] && break
  sleep 1
done

remaining="$(printf '%s' "$pending" | grep -c . || true)"
if [ "$remaining" -gt 0 ]; then
  printf '\n⚠ %s session(s) still blank after %ss — they may still be replaying\n' \
    "$remaining" "$wait_secs"
  printf '  a long transcript. Give them a moment before opening the picker:\n'
  printf '  %s\n' $pending
else
  printf '\nAll panes rendered. Safe to open the picker.\n'
fi
[ "$fail" -eq 0 ]
