#!/usr/bin/env bash
# Interactive picker for running Claude sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  fmt=$(printf '#{session_name}\037#{@claude_state}\037#{@claude_state_at}\037#{pane_pid}\037#{@claude_title}\037#{pane_current_path}')
  sessions=$(tmux list-sessions -F "$fmt" 2>/dev/null | grep "^${prefix}")
  [ -z "$sessions" ] && return

  # pane-root pid -> its claude-subtree pids, resolved in one awk pass and stashed
  # in a bash map so the row loop does zero per-row process walking.
  roots=$(printf '%s\n' "$sessions" | cut -d$'\037' -f4 | tr '\n' ' ')
  subtrees=$(claude_subtrees "$roots" "$ps_snap")
  declare -A SUB
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    root=${line%% *}; SUB[$root]=${line#* }
  done <<<"$subtrees"

  printf '%s\n' "$sessions" | while IFS=$'\037' read -r s state at pid ctitle path; do
    # Freshest explicitly-named sessions/<pid>.json across this pane's claude
    # subtree. A user-set name (--name or /rename) has NO nameSource; an auto-
    # derived one is tagged "nameSource":"derived". Prefer explicit names; else the
    # launcher's @claude_title (dir#N); else the dir basename. (pane_title avoided
    # — for an unnamed session it holds Claude's auto-summary, not a label.)
    title=""; best_m=0
    for cp in ${SUB[$pid]}; do
      cf="$HOME/.claude/sessions/${cp}.json"
      [ -r "$cf" ] || continue
      # One grep pulls BOTH "name" and "nameSource"; first occurrence of each wins.
      src=""; cn=""
      while IFS= read -r kv; do
        case "$kv" in
          '"nameSource"'*) [ -z "$src" ] && { src=${kv#*:}; src=${src//\"/}; src=${src# }; } ;;
          '"name"'*)       [ -z "$cn"  ] && { cn=${kv#*:};  cn=${cn//\"/};  cn=${cn# }; } ;;
        esac
      done < <(LC_ALL=C /usr/bin/grep -oE '"name(Source)?"[[:space:]]*:[[:space:]]*"[^"]*"' "$cf" 2>/dev/null)
      [ "$src" = "derived" ] && continue
      [ -z "$cn" ] && continue
      cm=$(stat -f %m "$cf" 2>/dev/null)
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
    # the longest name. rank asc, then age asc (just-finished floats to group top).
    printf '%s\t%s\t%s\t%5s\t%-44s\t%s\n' "$rank" "$s" "$icon" "$ago" "$title" "${path/#$HOME/~}"
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

sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=3,4,5,6 \
  --reverse --cycle --header='Claude sessions · enter: jump · ctrl-x: kill  (rename via /rename in-session)' \
  --preview="tmux capture-pane -ept {2}" --preview-window='up,70%,follow' \
	--bind="load:reload-sync(sleep 2; $self --list)" \
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
