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

# Conversations already open in a tmux session. -mmin alone is not enough: a
# live session that has been idle for a few minutes looks stale on disk, and
# resuming it again puts the same conversation in two panes. Field 9 of the
# picker's snapshot is the sessionId; re-delimit with US first, because TAB is
# IFS whitespace and an empty field would shift the rest left.
live=" $("$DIR/picker.sh" --list 2>/dev/null | tr '\t' '\037' \
  | awk -F'\037' 'NF>8 && $9 != "" {print $9}' | tr '\n' ' ')"

claimed=" "                             # names taken this run (dry run has no
                                        # live sessions to collide with)
n=0
for f in "${files[@]}"; do
  id="$(basename "$f" .jsonl)"
  [[ "$live" == *" $id "* ]] && continue   # already open in a session

  # `claude -p` writes a transcript exactly like an interactive session does, so
  # every cron run in ~/prv/jobs looked like a session worth reviving. entrypoint
  # separates them: cli is a person, sdk-cli is headless (scheduled jobs,
  # subagents). Over 60 days that is 70 headless against 57 real. Matching on
  # path instead would miss the headless runs that land in ordinary project
  # directories. grep -m1 stops at the first hit — jq would read a 50MB file whole.
  [ "$(grep -m1 -o '"entrypoint":"[^"]*"' "$f" 2>/dev/null | cut -d'"' -f4)" = cli ] || continue
  path="$(jq -r 'select(.cwd) | .cwd' "$f" 2>/dev/null | head -1)"
  [ -d "$path" ] || continue            # moved or deleted since
  [ "$path" = "/" ] && continue         # started from root; nothing to resume into

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

  # --max is per directory, not per run. One busy directory has far more
  # transcripts than the rest combined (42 vs 6 here), so a single global cap is
  # spent before any other directory is reached and those sessions never come
  # back. i-1 is already this directory's running count — the name suffix.
  [ $((i - 1)) -le "$max" ] || continue
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
  # Spell the whole command out. This normally runs in a popup, where there is
  # no shell to complete a path and nothing on screen to copy from.
  echo "--- dry run: $n sessions would be created. nothing was changed."
  echo
  echo "run this in a shell to create them:"
  echo "  $0 --go --days $days --max $max"
  echo
  echo "  --days N   how far back to look        (now $days)"
  echo "  --max  N   sessions per directory      (now $max)"
fi
