#!/usr/bin/env bash
# Recreate picker-tracked sessions after a reboot killed the tmux server.
#
# restart-all.sh resumes sessions that are still alive. After a reboot none are,
# so the live-session picker (prefix+u) is empty and there is nothing to restart.
# This reads the transcripts on disk instead and spawns one session per recent
# conversation, resuming it by id — same naming as launch-new.sh, so the picker
# tracks them.
#
# Usage: restore-reboot.sh [--go] [--days N] [--max N]
#   default is a dry run; --go actually creates the sessions
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

go=0; days=3; max=12; pause=false
while [ $# -gt 0 ]; do
  case "$1" in
    --go) go=1 ;;
    --days) days="$2"; shift ;;
    --max) max="$2"; shift ;;
    --pause) pause=true ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Keep the popup readable when run from the key binding; same as restart-all.sh.
hold_open() {
  [ "$pause" = true ] || return 0
  printf '\n[any key to close]'
  [ -r /dev/tty ] && read -rsn1 < /dev/tty
}
trap hold_open EXIT

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
projects="$HOME/.claude/projects"

# Newest first, so --max keeps the most recent. -mmin +2 drops transcripts still
# being written to — a session that is alive right now, including the one you are
# running this from. Without it a live session gets a duplicate resumed alongside it.
files=()
while IFS= read -r line; do files+=("$line"); done < <(
  find "$projects" -maxdepth 2 -name '*.jsonl' -mtime "-$days" \
    -mmin +2 -not -path '*/-private-tmp*' -exec stat -f '%m %N' {} + 2>/dev/null \
    | sort -rn | cut -d' ' -f2-
)

claimed=" "                             # names taken this run (dry run has no
                                        # live sessions to collide with)
n=0
for f in "${files[@]}"; do
  [ "$n" -ge "$max" ] && break
  id="$(basename "$f" .jsonl)"
  path="$(jq -r 'select(.cwd) | .cwd' "$f" 2>/dev/null | head -1)"
  [ -d "$path" ] || continue            # moved or deleted since

  # /rename wins over the auto-generated title, same as the resume picker shows.
  # It lands in one of two places depending on when the session was renamed:
  # a custom-title.json sidecar, or a record inside the transcript itself.
  title="$(jq -r '.customTitle // empty' "${f%.jsonl}/custom-title.json" 2>/dev/null)"
  [ -n "$title" ] || title="$(grep -o '"customTitle":"[^"]*"' "$f" 2>/dev/null | tail -1 | cut -d'"' -f4)"
  [ -n "$title" ] || title="$(jq -r 'select(.type=="ai-title") | .aiTitle' "$f" 2>/dev/null | tail -1)"

  base="${prefix}$(session_hash "$path")"
  session="$base"; i=2
  while tmux has-session -t "$session" 2>/dev/null || [[ "$claimed" == *" $session "* ]]; do
    session="${base}-${i}"; ((i++))
  done
  claimed+="$session "

  printf '%-22s %-34s %s\n' "$session" "${title:-(untitled)}" "$path"
  n=$((n + 1))
  [ "$go" -eq 1 ] || continue

  tmux new-session -d -s "$session" -c "$path" \
    "printf '\033[5 q'; exec claude --resume $id --dangerously-skip-permissions"
  tmux set-option -t "$session" @claude_title "${title:-${path##*/}#$((i - 1))~reboot}"
done

if [ "$go" -eq 1 ]; then
  echo "--- $n sessions created. prefix+u to list."
else
  echo "--- dry run: $n sessions would be created. re-run with --go"
fi
