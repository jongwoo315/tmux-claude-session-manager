#!/usr/bin/env bash
# Record the most recently attached Claude session so `last.sh` can jump back to
# it without the picker. Invoked from the client-attached hook with the attached
# client's session name. Non-Claude sessions (the outer client) are ignored, so
# @claude_last_session keeps pointing at the session you were last inside.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
sess="${1:-}"

case "$sess" in
"$prefix"*) tmux set-option -g @claude_last_session "$sess" ;;
esac
