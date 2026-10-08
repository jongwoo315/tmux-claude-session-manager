#!/usr/bin/env bash
# Open the session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# The client the key binding was pressed on (passed as '#{client_name}').
client="${1:-}"

# The session of a client attached to a prefixed session — i.e. the popup we are
# inside, if any. Empty when invoked from a normal (non-popup) pane.
nested_session() {
  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v p="$prefix" 'index($2, p) == 1 { print $2; exit }'
}

# A client NOT attached to a prefixed session — the outer client that should host
# the picker popup.
host_client() {
  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v p="$prefix" 'index($2, p) != 1 { print $1; exit }'
}

# If we are inside a session popup, close it (detach its client)
sess="$(nested_session)"
if [ -n "$sess" ]; then
  tmux detach-client -s "$sess"
  # Wait until the session is gone
  for _ in $(seq 1 100); do
    [ -z "$(nested_session)" ] && break
    sleep 0.05
  done
fi

# Prefer the invoking client when it isn't a popup client — with several outer
# clients attached, the blind scan below can pick another terminal's client and
# the picker appears on the wrong window. From inside a popup the invoking
# client is the (now detached) popup client, so the filter rejects it and we
# fall back to the scan.
host=""
if [ -n "$client" ]; then
  host="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v c="$client" -v p="$prefix" '$1 == c && index($2, p) != 1 { print $1; exit }')"
fi
# From inside a popup the invoking client is the (now detached) popup client, so
# $host is still empty. That popup was hosted on @claude_parent (set when the
# picker opened); prefer it so the picker reopens on the SAME terminal instead of
# a blind scan that may land on another client attached to the same session.
if [ -z "$host" ]; then
  parent="$(tmux show-options -gqv @claude_parent 2>/dev/null)"
  [ -n "$parent" ] && host="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v c="$parent" -v p="$prefix" '$1 == c && index($2, p) != 1 { print $1; exit }')"
fi
[ -n "$host" ] || host="$(host_client)"
tmux set-option -g @claude_parent "$host"

# 새 세션이 처음부터 팝업 안쪽 크기로 뜨게 한다.
#
# 세션은 전부 `new-session -d`로 만들어져(새 세션·포크·재부팅 복원·orch) default-size
# (80x24)로 뜬다. 처음 picker로 붙는 순간 팝업 크기로 커지고, 폭이 바뀌면 Claude Code가
# 대화 전체를 새 폭으로 다시 찍는다 — 스크롤백에 옛 폭 사본과 새 폭 사본이 둘 다 남는다
# (2026-10-08 실측: 붙어 본 적 없는 세션 80x24, 붙은 세션 187x81).
#
# 숫자를 tmux.conf에 박지 않는 이유는 맥마다 바깥 터미널 크기가 달라서다. picker를 열 때
# 바깥 client 크기에서 계산한다: 팝업 = 바깥 × 비율(정수 나눗셈, tmux와 같다), 안쪽은
# 테두리 2칸을 빼고, 창 높이는 status 줄을 또 뺀다. 이미 떠 있는 세션은 바꾸지 않는다.
popup_inner() {   # $1=옵션값('90%' 또는 칸 수) $2=바깥 크기 -> 테두리 뺀 안쪽 크기
  case "$1" in
    *%) echo $(( $2 * ${1%\%} / 100 - 2 )) ;;
    *)  echo $(( $1 - 2 )) ;;
  esac
}
if [ -n "$host" ]; then
  # display -p -c 는 client_* 를 호출한 pane 쪽 client 로 풀어서 팝업 안에서 부르면
  # 팝업 크기가 나온다 — list-clients 에서 이름으로 고른다.
  read -r cw ch < <(tmux list-clients -F '#{client_name} #{client_width} #{client_height}' 2>/dev/null |
    awk -v c="$host" '$1 == c { print $2, $3; exit }')
  if [ -n "${cw:-}" ] && [ -n "${ch:-}" ]; then
    st="$(tmux show -gv status 2>/dev/null)"
    case "$st" in off) st=0 ;; on) st=1 ;; esac
    dw=$(popup_inner "$w" "$cw"); dh=$(( $(popup_inner "$h" "$ch") - ${st:-1} ))
    [ "$dw" -gt 20 ] && [ "$dh" -gt 5 ] && tmux set-option -g default-size "${dw}x${dh}"
  fi
fi

# Host the picker on the outer client. -c is honored because that client has no
# popup open now; fall back to the default client if none was found.
if [ -n "$host" ]; then
  tmux display-popup -c "$host" -w "$w" -h "$h" -E "$DIR/picker.sh"
else
  tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
fi
