#!/usr/bin/env bash
# Interactive picker for running Claude sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --preview is dispatched FIRST, before sourcing helpers and before reading any
# tmux option. fzf re-runs it on every j/k, so anything above it is paid per
# keystroke: the @claude_session_prefix lookup alone measured 10.4ms of a 25.9ms
# preview — 40% spent on a value the preview never reads. preview_pane needs only
# tmux and awk.
preview_pane() {
  [ -n "${1:-}" ] || return 0
  # Only as many lines as the preview window can show. fzf exports its geometry to
  # the preview command; without the cap this emitted 280 lines / 26KB into a ~51
  # row window on EVERY keystroke, and at key-repeat speed that is the better part
  # of a megabyte per second pushed through a tmux popup — which is what the j/k
  # "lag" actually was. Scrollback still comes in (-S) so the window stays full
  # even when the pane itself is mostly blank; it is just trimmed to fit.
  local want=$(( ${FZF_PREVIEW_LINES:-60} + 2 ))
  tmux capture-pane -ept "$1" -S -200 2>/dev/null | awk -v want="$want" '
    BEGIN { esc = sprintf("%c", 27) }
    {
      a[NR] = $0
      t = $0
      gsub(esc "\\[[0-9;?]*[a-zA-Z]", "", t)
      if (t ~ /[^[:space:]]/) last = NR
    }
    END {
      start = last - want + 1
      if (start < 1) start = 1
      for (i = start; i <= last; i++) print a[i]
    }'
}

[ "${1:-}" = '--preview' ] && {
  preview_pane "${2:-}"
  exit 0
}

# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

# Build, in ONE awk pass over a ps snapshot ($2), each pane root's claude-subtree
# pids: emits "<root> <claudePid>..." per root ($1 = space-separated roots). A
# /resume or fork spawns a NESTED claude with its own sessions/<pid>.json; tmux's
# pane_pid points at the OUTER claude, so we walk the subtree and later pick the
# freshest json. One awk for ALL rows (not per-row) — a per-row walk over each
# session's dozens of MCP/node children, every 2s reload, made the picker crawl.
claude_subtrees() {
  awk -v roots="$1" '
    { c=$3; sub(/.*\//, "", c); comm[$1]=c; kids[$2]=kids[$2] " " $1 }
    END {
      nr=split(roots, R, " ")
      for (r=1; r<=nr; r++) {
        root=R[r]; if (root=="") continue
        delete q; n=0; q[++n]=root; line=root
        for (i=1; i<=n; i++) {
          p=q[i]
          if (comm[p]=="claude") line=line " " p
          m=split(kids[p], a, " ")
          for (j=1; j<=m; j++) if (a[j] != "") q[++n]=a[j]
        }
        print line
      }
    }' <<<"$2"
}

# Pad $1 to $2 DISPLAY columns, result in $PADDED.
#
# bash's printf pads `%-44s` by BYTES, not display columns. A UTF-8 Hangul char is
# 3 bytes but renders 2 columns, so each one spent 3 of the 44-byte budget while
# advancing the cursor only 2 — the path column drifted LEFT one column per CJK
# char (a 6-char Korean title landed 6 columns short of the ASCII rows).
#
# Width without forking: ${#s} counts characters, and the SAME expansion under
# LC_ALL=C counts bytes. The surplus bytes identify the wide ones — a 3-byte CJK
# char and a 4-byte emoji each render 2 columns, a 2-byte accented Latin char
# renders 1, and (bytes-chars)/2 yields exactly the extra columns in all three.
# Assigning to a global (not echoing) keeps this fork-free; a $(...) per row would
# reintroduce the forks the single-ps/single-tmux design removed.
SPACES='                                                                  '
pad_display() {
  local s="$1" want="$2" chars bytes disp
  chars=${#s}
  local LC_ALL=C
  bytes=${#s}
  disp=$(( chars + (bytes - chars) / 2 ))
  if [ "$disp" -ge "$want" ]; then PADDED="$s"; else PADDED="$s${SPACES:0:$((want - disp))}"; fi
}

emit_rows() {
  local now ps_snap fmt sessions roots subtrees line root
  now=$(date +%s)
  ps_snap=$(ps -axo pid=,ppid=,comm=)

  # ONE tmux call for every field of every claude session (name, state, at, pane
  # pid, @claude_title, path) — replaces the per-row show-options x2 +
  # display-message (~4 forks/row) with a single list-sessions. Delimiter is \037
  # (unit separator), NOT tab: tab is a whitespace IFS char, so an empty middle
  # field (e.g. orch sessions have no @claude_title) would collapse and shift the
  # remaining columns. \037 never appears in a name or path.
  fmt=$(printf '#{session_name}\037#{@claude_state}\037#{@claude_state_at}\037#{pane_pid}\037#{@claude_title}\037#{pane_current_path}\037#{window_activity}')
  sessions=$(tmux list-sessions -F "$fmt" 2>/dev/null | grep "^${prefix}")
  [ -z "$sessions" ] && return

  # pane-root pid -> its claude-subtree pids, all roots resolved in ONE awk pass.
  # $subtrees holds "<root> <pid>..." lines; the row loop looks a root up with a
  # pure-bash while (no fork, no `declare -A` — macOS still ships bash 3.2, which
  # has no associative arrays).
  roots=$(printf '%s\n' "$sessions" | cut -d$'\037' -f4 | tr '\n' ' ')
  subtrees=$(claude_subtrees "$roots" "$ps_snap")

  printf '%s\n' "$sessions" | while IFS=$'\037' read -r s state at pid ctitle path wact; do
    # A user ESC-interrupt ends the turn without firing ANY hook — Claude Code has
    # no interrupt event, and Stop only fires on a normal finish — so `working`
    # sticks (red) until the next prompt. Cross-check it against tmux's own
    # activity clock: a working session repaints its spinner and elapsed timer
    # about once a second, so #{window_activity} is always within a couple of
    # seconds of now; an interrupted one froze at the prompt and stops advancing.
    # (Measured: the working session 0s ago, all 12 idle ones >=575s.) The field
    # rides along in the list-sessions call above, so this costs nothing — no
    # capture, no sampling delay. Display-only: @claude_state is left alone so
    # orch keeps reading the same value it always did.
    #
    # 30s, not 5s. A session waiting on a background shell or agent repaints only
    # when its elapsed-time line ticks, so it crossed a 5-second line constantly and
    # flapped working<->idle every couple of seconds. The picker re-sorts on state,
    # so each flap threw that row between the top and bottom of the list, and j/k
    # landed on whatever slid underneath — read as input lag, not as reordering.
    # The gap this discriminates is enormous (0s vs 575s+), so 30s costs nothing in
    # detection: an ESC-interrupted session is stale by minutes, never by seconds.
    [ "$state" = working ] && [ -n "$wact" ] && [ $((now - wact)) -gt 30 ] && state=idle
    pids=""
    while IFS= read -r line; do
      [ "${line%% *}" = "$pid" ] && { pids=${line#* }; break; }
    done <<<"$subtrees"
    # Freshest explicitly-named sessions/<pid>.json across this pane's claude
    # subtree. A user-set name (--name or /rename) has NO nameSource; an auto-
    # derived one is tagged "nameSource":"derived". Prefer explicit names; else the
    # launcher's @claude_title (dir#N); else the dir basename. (pane_title avoided
    # — for an unnamed session it holds Claude's auto-summary, not a label.)
    title=""; best_m=0; sid=""; sid_m=0
    for cp in $pids; do
      cf="$HOME/.claude/sessions/${cp}.json"
      [ -r "$cf" ] || continue
      # One grep pulls "name", "nameSource" AND "sessionId"; first of each wins.
      # Folded into the existing grep rather than run as a second pass — this loop
      # is the hot path the fork-reduction work was about.
      src=""; cn=""; csid=""
      while IFS= read -r kv; do
        case "$kv" in
          '"nameSource"'*) [ -z "$src" ]  && { src=${kv#*:};  src=${src//\"/};  src=${src# }; } ;;
          '"sessionId"'*)  [ -z "$csid" ] && { csid=${kv#*:}; csid=${csid//\"/}; csid=${csid# }; } ;;
          '"name"'*)       [ -z "$cn" ]   && { cn=${kv#*:};   cn=${cn//\"/};   cn=${cn# }; } ;;
        esac
      done < <(LC_ALL=C /usr/bin/grep -oE '"(name|nameSource|sessionId)"[[:space:]]*:[[:space:]]*"[^"]*"' "$cf" 2>/dev/null)
      cm=$(stat -f %m "$cf" 2>/dev/null)
      # sessionId tracks the freshest json REGARDLESS of nameSource — the transcript
      # lookup needs it even for a session whose name was auto-derived, and those
      # are skipped by the title rules below.
      [ -n "$csid" ] && [ "${cm:-0}" -ge "$sid_m" ] && { sid_m="${cm:-0}"; sid="$csid"; }
      [ "$src" = "derived" ] && continue
      [ -z "$cn" ] && continue
      [ "${cm:-0}" -ge "$best_m" ] && { best_m="${cm:-0}"; title="$cn"; }
    done
    [ -z "$title" ] && title="$ctitle"
    [ -z "$title" ] && title="${path##*/}"

    case "$state" in
    waiting) icon=$'\033[33m●\033[0m waiting' rank=0 ;; # yellow - needs input
    idle)    icon=$'\033[32m●\033[0m idle   ' rank=1 ;; # green  - done, your turn
    working) icon=$'\033[31m●\033[0m working' rank=3 ;; # red    - busy, leave it
    *)       icon=$'\033[90m●\033[0m   ?    ' rank=2 ;; # grey   - unknown (no hook yet)
    esac
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t session \t icon \t age \t title(padded) \t path. Title is space-
    # padded (not tab) so fzf's 8-col tabstop doesn't jump the path column; 44 fits
    # the longest name. Padded by pad_display, NOT printf's %-44s — that pads by
    # bytes and misaligns any CJK title. rank asc, then age asc (just-finished
    # floats to group top).
    # Field 7 (sessionId) is for web-server.js to locate the transcript; fzf renders
    # only fields 3..6, so it never shows up in the picker itself.
    pad_display "$title" 44
    printf '%s\t%s\t%s\t%5s\t%s\t%s\t%s\n' "$rank" "$s" "$icon" "$ago" "$PADDED" "${path/#$HOME/~}" "$sid"
  done | LC_ALL=C sort -t$'\t' -k1,1n -k4,4n
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit 0
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-claude-session-manager: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
export FZF_DEFAULT_OPTS=''

# Arbitrary user fzf options (custom --bind, --preview-window, ...). Appended
# last so they can override the defaults below. CLAUDE_PICKER lets a user bind
# reload the row list the way the built-in ctrl-x does.
export CLAUDE_PICKER="$self"
extra_opts=()
fzf_options="$(get_tmux_option @claude_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

# The popup inherits a steady-block cursor. fzf parks the real terminal cursor
# on its query line, so switch to a blinking bar (DECSCUSR 5) for the input and
# restore the default (0) on any exit path.
printf '\033[5 q' >/dev/tty 2>/dev/null || true
trap 'printf "\033[0 q" >/dev/tty 2>/dev/null || true' EXIT

# `load` fires after every list load, so binding reload to it makes a self-feeding
# 2-second refresh — measured at exactly 2s intervals for as long as the picker is
# open. That is intended (states must stay live), but BOTH details below are load-
# bearing and each was wrong at some point:
#
#   async `reload`, not `reload-sync` — sync holds fzf until the command returns,
#   so the UI froze for the whole cycle and j/k piled up behind it.
#
#   `--list; sleep 2`, NOT `sleep 2; --list` — reload empties the list immediately
#   and waits for output, so a leading sleep left the picker filtering an EMPTY
#   list for 2 of every 2.2 seconds. Measured: typing a query took 1697ms to show
#   results, against 133ms with no reload at all. Emitting first and sleeping
#   afterwards keeps the rows on screen the whole time and the delay between
#   refreshes unchanged — 127ms, i.e. the no-reload baseline, with 0 empty frames
#   sampled over 6 seconds.
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=3,4,5,6 \
  --reverse --cycle --header='Claude sessions · enter: jump · ctrl-x: kill  (rename via /rename in-session)' \
  --preview="$self --preview {2}" --preview-window='up,70%,follow' \
	--bind="load:reload($self --list; sleep 2)" \
  --bind="ctrl-x:execute-silent(tmux kill-session -t {2})+reload($self --list)" \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
target=$(printf '%s' "$sel" | LC_ALL=C cut -f2)

# Move the underlying parent client to the session's origin window (best-effort),
# then resume the session in THIS popup over it. Falls back to resuming over the
# current window when origin/parent are unknown.
origin=$(tmux show-options -qv -t "$target" @claude_origin 2>/dev/null)
parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
if [ -n "$origin" ] && [ -n "$parent" ]; then
  # Only relocate within the same session. All claude sessions share one origin
  # window, so an unconditional switch-client yanks the parent client across
  # sessions (e.g. aux -> orch) — a jarring, unexpected jump. Skip when the origin
  # window lives in a different session than the parent client is currently on.
  psess=$(tmux display-message -p -c "$parent" '#{session_name}' 2>/dev/null)
  osess=$(tmux display-message -p -t "$origin" '#{session_name}' 2>/dev/null)
  [ -n "$osess" ] && [ "$psess" = "$osess" ] &&
    tmux switch-client -c "$parent" -t "$origin" 2>/dev/null
fi

tmux attach-session -t "$target"
