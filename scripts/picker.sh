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

emit_rows() {
  local now s state at path icon rank ago title
  now=$(date +%s)
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${prefix}" | while IFS= read -r s; do
    state=$(tmux show-options -qv -t "$s" @claude_state 2>/dev/null)
    at=$(tmux show-options -qv -t "$s" @claude_state_at 2>/dev/null)
    path=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
    # Human label; falls back to the dir basename so same-dir sessions differ.
    title=$(tmux show-options -qv -t "$s" @claude_title 2>/dev/null)
    [ -z "$title" ] && title="${path##*/}"
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

# The popup inherits a steady-block cursor. fzf parks the real terminal cursor
# on its query line, so switch to a blinking bar (DECSCUSR 5) for the input and
# restore the default (0) on any exit path.
printf '\033[5 q' >/dev/tty 2>/dev/null || true
trap 'printf "\033[0 q" >/dev/tty 2>/dev/null || true' EXIT

sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=3,4,5,6 \
  --reverse --cycle --header='Claude sessions · enter: jump · ctrl-r: rename · ctrl-x: kill' \
  --preview="tmux capture-pane -ept {2}" --preview-window='right,62%,wrap' \
	--bind="start:reload($self --list)" \
	--bind="load:reload-sync(sleep 2; $self --list)" \
  --bind="ctrl-x:execute-silent(tmux kill-session -t {2})+reload($self --list)" \
  --bind="ctrl-r:execute($DIR/rename.sh {2})+reload($self --list)")

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
