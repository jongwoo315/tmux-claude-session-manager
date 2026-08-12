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
  read -r lines cols < <(stty size < /dev/tty 2>/dev/null || echo '')
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
  read -r _ TERM_COLS < <(stty size < /dev/tty 2>/dev/null || echo '')
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

hold_open() {
  [ "$pause" = true ] || return 0
  printf '\n'
  center_line '[any key to close]'
  read -rsn1 < /dev/tty
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

# --list is the picker's own snapshot: 2=session 3=state 5=title 6=cwd 7=sessionId.
rows="$("$DIR/picker.sh" --list 2>/dev/null)"
[ -n "$rows" ] || { printf 'No Claude sessions found.\n'; exit 0; }

plan=''    # session \t cwd \t sid \t title \t origin
busy=''
total=0
while IFS=$'\t' read -r _rank session state _age title cwd sid _prompt _n; do
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
  plan+="$session"$'\t'"$real"$'\t'"$sid"$'\t'"$(printf '%s' "$title" | sed 's/ *$//')"$'\t'"$origin"$'\n'
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
while IFS=$'\t' read -r s p sid t _o; do
  [ -n "$s" ] || continue
  printf '  %-38s %-26s %s\n' "$s" "${t:-—}" "${sid:-<no transcript — fresh start>}"
done <<< "$plan"

if [ "$go" = false ]; then
  printf '\nDry run. Re-run with --go to apply.\n'
  exit 0
fi

printf '\n'
fail=0
while IFS=$'\t' read -r session path sid title origin; do
  [ -n "$session" ] || continue
  # Reuse the user's configured command verbatim so wrappers survive (their
  # resume command is `printf '\033[5 q'; exec claude --resume …`, so the binary
  # is NOT the first word — splitting on whitespace would break it).
  if [ -n "$sid" ]; then
    if [[ "$resume_cmd" == *" --resume"* ]]; then
      cmd="${resume_cmd/ --resume/ --resume $sid}"
    else
      cmd="$resume_cmd --resume $sid"
    fi
  else
    cmd="$launch_cmd"
  fi
  tmux kill-session -t "$session" 2>/dev/null
  if tmux new-session -d -s "$session" -c "$path" "$cmd"; then
    [ -n "$origin" ] && tmux set-option -t "$session" @claude_origin "$origin"
    [ -n "$title" ]  && tmux set-option -t "$session" @claude_title "$title"
    printf '  ✓ %s\n' "$session"
  else
    printf '  ✗ %s — failed to recreate\n' "$session" >&2
    fail=$((fail + 1))
  fi
done <<< "$plan"

printf '\n%s restarted, %s failed.\n' "$((total - fail))" "$fail"

# Claude needs a few seconds to boot and replay the transcript; a pane opened
# before that is blank, which reads as a broken session in the picker. Wait for
# each pane to paint something before saying we are done.
wait_secs="$(get_tmux_option @claude_restart_wait 60)"
printf '\nWaiting for panes to render (up to %ss)…\n' "$wait_secs"
pending=''
while IFS=$'\t' read -r s _p _sid _t _o; do
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
