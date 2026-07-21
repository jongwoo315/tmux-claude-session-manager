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

# Extract a top-level JSON string field from a small file (no jq dependency).
#   json_str <file> <key>  ->  the string value, or empty.
json_str() {
  LC_ALL=C /usr/bin/grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null |
    head -1 | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*\"(.*)\"\$/\1/"
}

# Every claude pid in a pane's process subtree, one per line. A session that
# /resume-s or forks spawns a NESTED claude with its own sessions/<pid>.json; tmux
# pane_pid points at the OUTER claude, whose json name goes stale after an inner
# /rename. Walking the subtree lets emit_rows pick the freshest json instead.
#
# Resolved from the single $ps_snap snapshot (ps output), NOT by forking ps/pgrep
# per node — a recursive walk over each session's dozens of MCP/node children,
# every 2s reload, made the picker crawl. One awk BFS over the snapshot instead.
collect_claude_pids() {
  awk -v root="$1" '
    { c=$3; sub(/.*\//, "", c); comm[$1]=c; kids[$2]=kids[$2] " " $1 }
    END {
      q[++n]=root
      for (i=1; i<=n; i++) {
        p=q[i]
        if (comm[p]=="claude") print p
        m=split(kids[p], a, " ")
        for (j=1; j<=m; j++) if (a[j] != "") q[++n]=a[j]
      }
    }
  ' <<<"$ps_snap"
}

emit_rows() {
  local now s state at path icon rank ago title ps_snap
  now=$(date +%s)
  # One process snapshot for the whole render; collect_claude_pids reads it.
  ps_snap=$(ps -axo pid=,ppid=,comm=)
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${prefix}" | while IFS= read -r s; do
    state=$(tmux show-options -qv -t "$s" @claude_state 2>/dev/null)
    at=$(tmux show-options -qv -t "$s" @claude_state_at 2>/dev/null)
    path=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
    # Human label. Claude records each running session in
    # ~/.claude/sessions/<pid>.json with a "name" and a "nameSource": a name the
    # user set (via --name or /rename) has NO nameSource, while an auto-derived
    # name is tagged "nameSource":"derived". Show the name only when it's explicit;
    # for derived/unnamed sessions fall back to the launcher's @claude_title
    # (dir#N) and finally the dir basename. Across the pane's claude subtree pick
    # the freshest explicitly-named json (newest mtime) — that's the session the
    # user is actually in, and the one an inner /rename touched. (pane_title is
    # avoided: for an unnamed session it holds Claude's auto-summary, not a label.)
    pid=$(tmux display-message -p -t "$s" '#{pane_pid}' 2>/dev/null)
    title=""; best_m=0
    for cp in $(collect_claude_pids "$pid"); do
      cf="$HOME/.claude/sessions/${cp}.json"
      [ -r "$cf" ] || continue
      [ "$(json_str "$cf" nameSource)" = "derived" ] && continue
      cn=$(json_str "$cf" name)
      [ -z "$cn" ] && continue
      cm=$(stat -f %m "$cf" 2>/dev/null)
      [ "${cm:-0}" -ge "$best_m" ] && { best_m="${cm:-0}"; title="$cn"; }
    done
    if [ -z "$title" ]; then
      title=$(tmux show-options -qv -t "$s" @claude_title 2>/dev/null)
      [ -z "$title" ] && title="${path##*/}"
    fi
    case "$state" in
    waiting) icon=$'\033[33m●\033[0m waiting' rank=0 ;; # yellow - needs input
    idle) icon=$'\033[32m●\033[0m idle   ' rank=1 ;;    # green  - done, your turn
    working) icon=$'\033[31m●\033[0m working' rank=3 ;; # red    - busy, leave it
    *) icon=$'\033[90m●\033[0m   ?    ' rank=2 ;;       # grey   - unknown (no hook yet)
    esac
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t session \t icon \t age \t title \t path (rank/session hidden via --with-nth)
    printf '%s\t%s\t%s\t%5s\t%s\t%s\n' "$rank" "$s" "$icon" "$ago" "$title" "${path/#$HOME/~}"
    # rank asc (attention-needed floats up), then age asc so the session that
    # finished just now sits at the top of its group. -k4,4n reads the leading
    # number of the age field ("5m" -> 5; "-" -> 0).
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
	--bind="start:reload($self --list)" \
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
