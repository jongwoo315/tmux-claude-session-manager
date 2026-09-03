#!/usr/bin/env bash
# Interactive picker for running Claude sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       chosen session's origin window and resumes it in the popup.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The preview runs on EVERY j/k, so everything on that path is paid per keystroke.
# It used to re-enter this script (`picker.sh --preview`), which cost a second bash
# startup plus a parse of the whole file: 19.2ms per keystroke against 11.3ms for
# the same pipeline run directly, measured over 40 runs each. fzf executes the
# --preview string with `sh -c`, so the pipeline goes there verbatim and only tmux
# and awk are spawned.
#
# Holding j/k is smooth while tapping it is not, because fzf skips the preview
# entirely while more input is pending — so the per-keystroke preview cost IS the
# lag, and it only shows up when you move one row at a time.
#
# Only as many lines as the preview window can show. fzf exports its geometry to
# the preview command; without the cap this emitted 280 lines / 26KB into a ~51 row
# window on every keystroke. Scrollback still comes in (-S) so the window stays
# full even when the pane itself is mostly blank; it is just trimmed to fit. -S -80
# rather than -200: the trim never needs more than `want` lines of history and the
# smaller capture is measurably cheaper (9.9ms vs 11.3ms).
#
# The awk program travels in the environment instead of being quoted into the
# --preview string. Expanding "$CLAUDE_PREVIEW_AWK" inside sh yields the text
# literally — the result of a parameter expansion is not rescanned — so the $0 and
# the backslashes in the program survive without a second layer of escaping.
export CLAUDE_PREVIEW_AWK='
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
# Column width the frozen notice wraps to. Fixed rather than derived from the
# window: the preview runs ~168 columns wide here, so anything comfortably under
# that both reads well and lets --list decide the wrap while the preview only has
# to shift the block right by a constant.
NOTICE_W=72

# Field 8 of a row is empty for a session whose pane is still moving, and holds a
# ready-made notice for one that has not repainted in @claude_preview_max_age
# seconds. Capturing those is pure waste — a pane idle for days renders the same
# bytes on every keystroke — so the notice is printed instead and tmux is never
# asked. 34.5ms -> 13.9ms per keystroke at the spacing that actually hurts (one
# tap per ~0.8s; holding j/k costs neither, fzf skips the preview while input is
# pending). 13.9ms is the floor: fzf still spawns one sh per row and no per-item
# branch can avoid that.
#
# The decision is made in --list, not here, because --list already reads
# #{window_activity} and knows `now`. Doing it in the preview would cost a second
# tmux round trip, which is the thing being removed.
# {10} is NOT wrapped in quotes here: fzf substitutes placeholders already shell
# quoted, so "{10}" on an empty field yields a literal '' — two apostrophes, which
# test -n reads as non-empty and every row printed them instead of a preview.
#
# The notice is centred in the window. {11} is its row count and NOTICE_W its fixed
# column width, both settled in --list, so the offsets are two subtractions and no
# measuring. Everything here is a shell builtin — adding an awk just to lay out a
# handful of lines would put a third of the saved time back.
#
# {11} is assigned to _n before any arithmetic touches it. fzf runs this with
# $SHELL, which is zsh on this machine, and fzf substitutes placeholders shell
# quoted — zsh rejects the quoted operand in $(( x - '18' )) outright, so the
# whole preview came back as a math error.
#
# Written on ONE line so the same string can also be handed to a --bind action.
# fzf parses a bind action up to its matching paren and a literal newline inside
# it silently swallows the whole binding, so the readable indented form could not
# be reused for the ctrl-o restore below.
PREVIEW_CMD='[ -n {10} ] && { _t={10}; _n={11}; _pad=""; _i=0; _down=$(( ( ${FZF_PREVIEW_LINES:-40} - _n ) / 2 )); _in=$(( ( ${FZF_PREVIEW_COLUMNS:-80} - '"$NOTICE_W"' ) / 2 )); while [ $_i -lt $_down ]; do printf "\n"; _i=$(( _i + 1 )); done; _i=0; while [ $_i -lt $_in ]; do _pad="$_pad "; _i=$(( _i + 1 )); done; printf "%b\n" "$_pad${_t//\\n/\\n$_pad}"; exit 0; }; tmux capture-pane -ept {2} -S -80 2>/dev/null | awk -v want=$(( ${FZF_PREVIEW_LINES:-60} + 2 )) "$CLAUDE_PREVIEW_AWK"'

# ctrl-g swaps the preview over to the live pane; ctrl-o swaps back.
#
# `change-preview` rather than the one-shot `preview(...)`, which is what this
# wanted to be: fzf's transient preview is wiped by the next preview refresh, and
# the 2s auto-reload refreshes it constantly. Measured — the pane showed for about
# 0.5s and the notice was back by 1.0s, every time. A mode you have to leave
# explicitly is worse than one that expires, but a mode that expires in half a
# second is not a mode at all.
#
# Deeper and taller than the always-on path: 2000 lines of scrollback and 500 rows
# emitted, so the window can be scrolled back through a long run. Those were kept
# small on the always-on path precisely because they were paid on every keypress;
# here you asked for it. While this mode is on, j/k does pay the capture cost
# again — that is the trade, and ctrl-o ends it.
#
# The trailing echo is the way back out. --preview-window has `follow`, so the
# view sits at the end of the output and that line is what you are looking at.
PANE_CMD='tmux capture-pane -ept {2} -S -2000 2>/dev/null | awk -v want=500 "$CLAUDE_PREVIEW_AWK"; printf "\n\033[7m ctrl-o: back to prompt \033[0m\n"'

# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

# How long an idle session may go without a turn before its pane preview is
# replaced by a notice. Three shapes:
#
#   never | prompt   never capture a pane. Every row shows its last prompt, and
#                    ctrl-g pulls up the live screen on demand.
#   off | none | 0   always capture. The original behaviour.
#   <n>[smhd]        capture only within that window (working/waiting exempt).
#
# `never` is the default because the age rule stops helping once enough sessions
# are active: capturing a pane costs ~28ms per keypress against ~13ms for the
# notice, and the ~13ms is the floor (fzf spawns one sh per row no matter what).
# With a dozen live sessions the age rule leaves most rows capturing again and
# the lag comes straight back. The last prompt turns out to carry more context
# per row than a screenful of scrollback anyway — it says what the session was
# asked to do, where the pane only shows where it happens to be sitting.
preview_max_age="$(get_tmux_option @claude_preview_max_age 'never')"
case "$preview_max_age" in
never | prompt) preview_max_age=-1 ;;
off | none) preview_max_age=0 ;;
*d) preview_max_age=$(( ${preview_max_age%d} * 86400 )) ;;
*h) preview_max_age=$(( ${preview_max_age%h} * 3600 )) ;;
*m) preview_max_age=$(( ${preview_max_age%m} * 60 )) ;;
*s) preview_max_age=${preview_max_age%s} ;;
esac
case "$preview_max_age" in -1) ;; '' | *[!0-9]*) preview_max_age=-1 ;; esac

# Whole units, largest that still reads as a round number. No fork.
human_age() {
  local s="$1"
  if [ "$s" -ge 86400 ]; then HUMAN="$((s / 86400))d"
  elif [ "$s" -ge 3600 ]; then HUMAN="$((s / 3600))h"
  elif [ "$s" -ge 60 ]; then HUMAN="$((s / 60))m"
  else HUMAN="${s}s"; fi
}

# Build, in ONE awk pass over a ps snapshot ($2), each pane root's claude-subtree
# pids: emits "<root> <claudePid>..." per root ($1 = space-separated roots). A
# /resume or fork spawns a NESTED claude with its own sessions/<pid>.json; tmux's
# pane_pid points at the OUTER claude, so we walk the subtree and later pick the
# freshest json. One awk for ALL rows (not per-row) — a per-row walk over each
# session's dozens of MCP/node children, every 2s reload, made the picker crawl.
#
# $3 is the space-separated set of pids that own a sessions/<pid>.json, and it is
# what identifies a claude here — the snapshot no longer carries `comm`. Asking ps
# for comm costs 20ms of the ~107ms refresh (44.8 -> 24.5, measured at 877
# processes) because it resolves an executable name per process, and json_scan has
# already produced the same answer for free: those files are named by claude pid.
claude_subtrees() {
  awk -v roots="$1" -v jpids="$3" '
    BEGIN { nj=split(jpids, J, " "); for (i=1; i<=nj; i++) if (J[i] != "") isclaude[J[i]]=1 }
    { kids[$2]=kids[$2] " " $1 }
    END {
      nr=split(roots, R, " ")
      for (r=1; r<=nr; r++) {
        root=R[r]; if (root=="") continue
        delete q; n=0; q[++n]=root; line=root
        for (i=1; i<=n; i++) {
          p=q[i]
          if (p in isclaude) line=line " " p
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
# 표시 폭 -> $DISPW. LC_ALL 을 여기 가둔다 — pad_display 안에서 켜면 이후의
# ${t#?} 까지 바이트 단위가 되어 한글이 쪼개진다.
_dispw() {
  # 한 줄에 몰면 안 된다 — `local x="$1" c=${#x}` 는 set -u 아래서
  # "x: unbound variable" 로 죽는다. 같은 local 문의 좌변은 아직 안 보인다.
  local x="$1" c b
  c=${#x}
  local LC_ALL=C
  b=${#x}
  DISPW=$(( c + (b - c) / 2 ))
}

# pad_display <문자열> <폭> [head|tail]
#
# 넘칠 때 자른다. 예전에는 그대로 뒀는데, 그러면 뒤 열이 통째로 밀린다 —
# 2026-09-03 실측: git 열(폭 22)에 "feature/DEV-7015-cross-encoder-reranker *1"
# 이 들어와 42 폭을 먹었고 링크·경로 열이 행마다 다른 자리에서 시작했다.
#
# 기본은 head — 앞을 남기고 뒤를 자른다. 모든 열이 같은 방향이라야 눈이 왼쪽
# 끝만 훑어도 읽힌다. tail 은 반대로 앞을 버리는데, 지금 쓰는 열은 없다.
pad_display() {
  local s="$1" want="$2" keep="${3:-head}" t
  _dispw "$s"
  if [ "$DISPW" -le "$want" ]; then PADDED="$s${SPACES:0:$((want - DISPW))}"; return; fi
  t="$s"
  if [ "$keep" = tail ]; then
    while _dispw "$t"; [ "$DISPW" -gt $((want - 2)) ] && [ -n "$t" ]; do t="${t#?}"; done
    t="..$t"
  else
    while _dispw "$t"; [ "$DISPW" -gt $((want - 2)) ] && [ -n "$t" ]; do t="${t%?}"; done
    t="$t.."
  fi
  _dispw "$t"
  if [ "$DISPW" -lt "$want" ]; then PADDED="$t${SPACES:0:$((want - DISPW))}"; else PADDED="$t"; fi
}

# Every sessions/<pid>.json in ONE awk pass, emitting "pid mtime src sid name".
#
# The row loop used to fork a grep AND a stat per json — ~32 forks per refresh with
# 16 sessions, and the refresh runs every 2.2s for as long as the picker is open.
# That is fine on an idle machine and not fine on a working one: measured at load
# 3.5 with 948 processes, a bare fork cost 8.9ms, so the forks alone dominated the
# 200ms build. This is the "it gets slow again after a while" — not the list logic
# growing, but fork getting expensive as sessions and their MCP children pile up.
#
# mtimes arrive via one `stat` on the whole glob and are handed to awk as a
# preloaded map, so the pass adds no per-file process. Values are pulled with
# match()/substr() rather than a capture group because macOS awk has no gensub, and
# accumulated per FILENAME then flushed at END because it has no ENDFILE either.
json_scan() {
  local d="$HOME/.claude/sessions" mt
  mt=$(stat -f '%m %N' "$d"/*.json 2>/dev/null) || return 0
  # Handed over as an environment variable, not `awk -v`: -v assignments cannot
  # contain a literal newline and macOS awk aborts with "newline in string" — which
  # it reports on stderr while still exiting 0, so with stderr suppressed the pass
  # silently produced nothing and every title fell back to @claude_title.
  MT="$mt" LC_ALL=C awk '
    function val(s) { sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s); return s }
    BEGIN {
      n = split(ENVIRON["MT"], L, "\n")
      for (i = 1; i <= n; i++) { split(L[i], p, " "); if (p[2] != "") M[p[2]] = p[1] }
    }
    {
      f = FILENAME
      files[f] = 1
      if (!(f in nm)  && match($0, /"name"[ \t]*:[ \t]*"[^"]*"/))
        nm[f]  = val(substr($0, RSTART, RLENGTH))
      if (!(f in sr)  && match($0, /"nameSource"[ \t]*:[ \t]*"[^"]*"/))
        sr[f]  = val(substr($0, RSTART, RLENGTH))
      if (!(f in sid) && match($0, /"sessionId"[ \t]*:[ \t]*"[^"]*"/))
        sid[f] = val(substr($0, RSTART, RLENGTH))
    }
    END {
      for (f in files) {
        pid = f; sub(/.*\//, "", pid); sub(/\.json$/, "", pid)
        # \037, not tab: nameSource is ABSENT for an explicitly named session, and
        # tab is an IFS whitespace character, so bash `read` collapses the run of
        # delimiters around the empty field and every later field shifts left — the
        # sessionId landed in nameSource and the name in sessionId, so titles fell
        # back to @claude_title. Same reason the list rows below use \037.
        printf "%s\037%s\037%s\037%s\037%s\n", pid, (f in M ? M[f] : 0), \
               (f in sr ? sr[f] : ""), (f in sid ? sid[f] : ""), (f in nm ? nm[f] : "")
      }
    }' "$d"/*.json 2>/dev/null
}

# Per-root title + sessionId, emitted as "<root>\037<title>\037<sid>" per line.
#
# This is the expensive half of a refresh — ps, every sessions/*.json, and a
# subtree walk — and it is the half that almost never changes. Split out so the
# cache below can skip it while the state columns stay live. See load_titles.
resolve_titles() {
  local roots="$1" ps_snap jscan jpids f subtrees line pid pids cp cm src csid cn
  local title best_m sid sid_m
  # No `comm` and no `-a`: the claude test comes from the json pid set below, and
  # -a would add every other user's processes (876 rows vs 684) for nothing.
  ps_snap=$(ps -xo pid=,ppid=)
  jscan=$(json_scan)
  # The sessions dir listing IS the claude pid set. Glob + parameter expansion,
  # so no fork and no herestring — bash 3.2 backs `<<<` with a real temp file.
  jpids=''
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    f=${f##*/}
    jpids="$jpids ${f%.json}"
  done
  subtrees=$(claude_subtrees "$roots" "$ps_snap" "$jpids")

  for pid in $roots; do
    pids=""
    while IFS= read -r line; do
      [ "${line%% *}" = "$pid" ] && { pids=${line#* }; break; }
    done <<<"$subtrees"
    # Freshest explicitly-named sessions/<pid>.json across this pane's claude
    # subtree. A user-set name (--name or /rename) has NO nameSource; an auto-
    # derived one is tagged "nameSource":"derived". Prefer explicit names; the
    # caller falls back to @claude_title and then the dir basename when this is
    # empty. (pane_title avoided — for an unnamed session it holds Claude's
    # auto-summary, not a label.)
    title=""; best_m=0; sid=""; sid_m=0
    for cp in $pids; do
      cm=""; src=""; csid=""; cn=""
      while IFS=$'\037' read -r jp jm jsrc jsid jn; do
        [ "$jp" = "$cp" ] || continue
        cm="$jm"; src="$jsrc"; csid="$jsid"; cn="$jn"; break
      done <<<"$jscan"
      [ -z "$cm" ] && continue
      # sessionId tracks the freshest json REGARDLESS of nameSource — the transcript
      # lookup needs it even for a session whose name was auto-derived, and those
      # are skipped by the title rules below.
      [ -n "$csid" ] && [ "${cm:-0}" -ge "$sid_m" ] && { sid_m="${cm:-0}"; sid="$csid"; }
      [ "$src" = "derived" ] && continue
      [ -z "$cn" ] && continue
      [ "${cm:-0}" -ge "$best_m" ] && { best_m="${cm:-0}"; title="$cn"; }
    done
    printf '%s\037%s\037%s\n' "$pid" "$title" "$sid"
  done
}

# Adds a 4th field, the session's last typed prompt, to resolve_titles' output.
#
# One `last-prompt.py` for the whole list, not one per row: transcripts reach
# 86MB so only their tails can be read, and doing that in the shell would be a
# `tail` plus a parser per session. A single interpreter start covering all 17
# measured 62ms warm, and it lands on the cache-rebuild path (every 15s at most),
# never on the keystroke path.
#
# python3 is optional. Without it every prompt is empty and the frozen-preview
# notice simply omits that section — the picker itself does not depend on python.
#
# Each sid carries a cutoff, and it is only non-zero for a pane sitting `idle`.
# The transcript belongs to the CONVERSATION, so `claude --resume` on the same one
# from a second window appends its turns to the same file under the same
# sessionId — the row then advertised a prompt this pane never saw (observed on a
# session whose transcript ran on for 287 minutes after its own last turn). An
# idle pane's last turn has already ended, so nothing stamped after it is its own.
# Deliberately NOT applied to working/bg/waiting rows: @claude_state_at is frozen
# for the length of a background-agent episode, so a prompt typed during one is
# legitimately newer than the stamp and would be discarded.
add_prompts() {
  local rows="$1" sids='' line pid title sid prompts='' live pp pstate pat cut
  live=$(tmux list-sessions -F "#{pane_pid}$(printf '\037')#{@claude_state}$(printf '\037')#{@claude_state_at}" 2>/dev/null)
  while IFS=$'\037' read -r pid title sid; do
    [ -n "$sid" ] || continue
    cut=0
    while IFS=$'\037' read -r pp pstate pat; do
      [ "$pp" = "$pid" ] || continue
      # 60s of slack: a just-submitted prompt and its stamp share a moment, and
      # the two clocks (record timestamp, date +%s) are not the same source.
      [ "$pstate" = idle ] && [ -n "$pat" ] && cut=$((pat + 60))
      break
    done <<<"$live"
    sids="$sids $sid:$cut"
  done <<<"$rows"
  if [ -n "$sids" ] && command -v python3 >/dev/null 2>&1; then
    prompts=$(python3 "$DIR/last-prompt.py" $sids 2>/dev/null)
  fi
  while IFS=$'\037' read -r pid title sid; do
    [ -n "$pid" ] || continue
    local prompt=''
    if [ -n "$sid" ] && [ -n "$prompts" ]; then
      local psid ptext
      while IFS=$'\t' read -r psid ptext; do
        [ "$psid" = "$sid" ] && { prompt="$ptext"; break; }
      done <<<"$prompts"
    fi
    printf '%s\037%s\037%s\037%s\n' "$pid" "$title" "$sid" "$prompt"
  done <<<"$rows"
}

# Greedy wrap of $1 to $2 display columns, result in $WRAPPED as one line per row
# joined by a literal backslash-n (rows are newline delimited, so a real newline
# cannot travel in a field). Width is counted the way pad_display counts it: a
# CJK char is 3 bytes but 2 columns, so (bytes-chars)/2 is the surplus.
wrap_text() {
  local text="$1" want="$2" word out='' cur='' w
  WRAPPED=''
  for word in $text; do
    if [ -z "$cur" ]; then cur="$word"; continue; fi
    w="$cur $word"
    local chars=${#w} bytes
    local LC_ALL=C
    bytes=${#w}
    if [ $((chars + (bytes - chars) / 2)) -le "$want" ]; then
      cur="$w"
    else
      out="$out$cur\\n"
      cur="$word"
    fi
  done
  [ -n "$cur" ] && out="$out$cur"
  WRAPPED="$out"
}

# Split refresh. State (working/waiting/idle) must be live — that is the whole
# point of the picker — but titles and sessionIds are the slow half and change
# only on a new session or an in-session /rename.
#
# The refresh runs every 2.1s for as long as the picker is open, and it competes
# with the popup for the SAME tmux server. Measured key->screen latency at 17
# sessions, 48 samples per variant over 3 interleaved rounds: 50ms p50 with the
# full refresh, 22ms with this half cached, 21ms with no refresh at all. So the
# slow half accounts for essentially all of the interactive lag.
#
# Invalidation has three keys, checked in this order:
#
#   1. root pid set — a created or killed session rebuilds at once, so a new
#      session is never shown untitled.
#   2. newest mtime across ~/.claude/sessions/*.json — this is what makes an
#      in-session /rename show up. Claude rewrites that file on rename (and on
#      every turn boundary), so it is an exact signal, not a heuristic.
#   3. TTL, purely as a backstop for anything the first two miss.
#
# Key 2 replaced a 15s TTL that WAS the rename delay: measured 16.0s before a
# renamed session took its new name, plus up to one 2.1s refresh on top. The
# obvious worry is that these files churn and defeat the cache, so it was
# measured first — over 30s, 1 of 18 files changed, once. The stat costs one
# fork on the refresh path (never on the keystroke path).
TITLE_TTL=120
TITLE_CACHE="${TMPDIR:-/tmp}/tmux-claude-picker-titles.$UID"

# Newest mtime across the session json files AND the transcripts, or 0. One `stat`
# over both globs and a pure-bash max — no sort/tail pipeline, which would be two
# more forks for a comparison bash can do.
#
# The transcripts are in here because sessions/<pid>.json does NOT move when a
# prompt arrives. Measured across the live list: one session's json was 5558s
# behind its transcript, another 12342s — they are written on status transitions,
# not on turns, so keying on them alone left `your last prompt` stale until the
# 120s backstop expired. The transcript is written on every turn, so it is the
# signal that actually matches what the notice shows.
#
# The obvious cost is that ANY of the ~119 transcripts changing rebuilds the
# cache, so it was measured first: 1 of 20 samples over 40s. The wider stat costs
# 10.7ms against 7.7ms for sessions alone.
sessions_stamp() {
  local out m
  STAMP=0
  out=$(stat -f '%m' "$HOME"/.claude/sessions/*.json \
    "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null)
  for m in $out; do
    [ "$m" -gt "$STAMP" ] && STAMP=$m
  done
  return 0
}

# Fills $TITLES from the cache; returns 1 (miss) if absent, stale, or built for a
# different set of sessions. Reads line-by-line rather than $(cat …) — a fork here
# would eat a third of what the cache saves.
load_titles() {
  local roots="$1" now="$2" stamp="$3" built sig cstamp line first=1
  TITLES=''
  [ -f "$TITLE_CACHE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      built=${line%%$'\037'*}
      line=${line#*$'\037'}
      cstamp=${line%%$'\037'*}
      sig=${line#*$'\037'}
      [ "$sig" = "$roots" ] || return 1
      [ "$cstamp" = "$stamp" ] || return 1
      case "$built" in '' | *[!0-9]*) return 1 ;; esac
      [ $((now - built)) -le "$TITLE_TTL" ] || return 1
      continue
    fi
    TITLES="$TITLES$line
"
  done <"$TITLE_CACHE"
  [ "$first" = 0 ] || return 1
  return 0
}

# Written to a temp name and renamed so a concurrent picker never reads a half
# written cache (two popups can be open on different clients).
save_titles() {
  local roots="$1" now="$2" stamp="$3" body="$4" tmp="$TITLE_CACHE.$$"
  {
    printf '%s\037%s\037%s\n' "$now" "$stamp" "$roots"
    printf '%s' "$body"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$TITLE_CACHE" 2>/dev/null ||
    rm -f "$tmp" 2>/dev/null
  return 0
}

emit_rows() {
  local now fmt sessions roots root line i frozen frozen_rows idle_for prompt
  local -a T_PID T_TITLE T_SID T_PROMPT
  now=$(date +%s)

  # ONE tmux call for every field of every claude session (name, state, at, pane
  # pid, @claude_title, path) — replaces the per-row show-options x2 +
  # display-message (~4 forks/row) with a single list-sessions. Delimiter is \037
  # (unit separator), NOT tab: tab is a whitespace IFS char, so an empty middle
  # field (e.g. orch sessions have no @claude_title) would collapse and shift the
  # remaining columns. \037 never appears in a name or path.
  fmt=$(printf '#{session_name}\037#{@claude_state}\037#{@claude_state_at}\037#{pane_pid}\037#{@claude_title}\037#{pane_current_path}\037#{window_activity}\037#{@claude_bg}\037#{@claude_git}\037#{@claude_link}\037#{@claude_fork_of}')
  # Filtered by tmux, not by a piped grep: -f evaluates the same prefix test
  # server-side and saves a fork per refresh (verified to select the identical 17
  # sessions). #{m:...} is a glob match, so the prefix needs a trailing *.
  sessions=$(tmux list-sessions -f "#{m:${prefix}*,#{session_name}}" -F "$fmt" 2>/dev/null)
  [ -z "$sessions" ] && return

  # Roots collected in-loop rather than `cut | tr` — two more forks for a field
  # split bash already does. Doubles as the cache key.
  roots=''
  while IFS=$'\037' read -r _ _ _ root _; do
    [ -n "$root" ] && roots="$roots $root"
  done <<<"$sessions"

  sessions_stamp
  load_titles "$roots" "$now" "$STAMP" || {
    TITLES="$(add_prompts "$(resolve_titles "$roots")")
"
    save_titles "$roots" "$now" "$STAMP" "$TITLES"
  }

  # Parallel arrays, not a herestring per row: bash 3.2 has no associative arrays
  # and backs `<<<` with a real temp file, so a lookup inside the row loop would
  # create one per session on every refresh. One herestring here, then an indexed
  # scan the row loop below can do fork-free. The pipeline's subshell inherits
  # these.
  while IFS=$'\037' read -r line title sid prompt; do
    [ -n "$line" ] || continue
    T_PID[${#T_PID[@]}]="$line"
    T_TITLE[${#T_TITLE[@]}]="$title"
    T_SID[${#T_SID[@]}]="$sid"
    T_PROMPT[${#T_PROMPT[@]}]="$prompt"
  done <<<"$TITLES"

  # 한 번의 렌더에서 새로 잴 세션 수. 아래 루프는 파이프 서브셸이라 이 카운터가
  # 밖으로 안 나가지만, 세는 단위가 렌더 하나라 그대로 맞다.
  FILLED=0
  GIT_FILL_MAX="$(get_tmux_option @claude_git_fill_max 3)"
  printf '%s\n' "$sessions" | while IFS=$'\037' read -r s state at pid ctitle path wact bg gitcol linkcol forkcol; do
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
    # A session parked on background work is stale by the same measure, so the
    # clock alone cannot separate the two. Raising the bar does not help: it was
    # already lifted 5s -> 30s for exactly this, and a background-parked session
    # was then measured frozen for 432s straight — every stray repaint bought 30s
    # of `working` and the row flapped back to idle after it, and since the picker
    # re-sorts on state each flap threw that row between the top and bottom of the
    # list, which reads as input lag rather than as reordering.
    #
    # @claude_bg settles it with the fact instead of a guess: state.sh sets it when
    # a Stop DID fire and only background tasks kept the session working. Those
    # rows skip the check and get their own display state below; a genuine
    # ESC-interrupt has no flag and is still caught. (Measured 2026-08-12: after an
    # ESC, zero hooks fire, @claude_state stays working, and window_activity stops
    # advancing — so the check is still load-bearing.)
    if [ "$state" = working ] && [ "$bg" = 1 ]; then
      state=background
    elif [ "$state" = working ] && [ -n "$wact" ] && [ $((now - wact)) -gt 30 ]; then
      state=idle
    fi
    # Indexed scan of the resolve_titles/cache result — no fork, no temp file.
    title=""; sid=""; i=0
    prompt=''
    while [ "$i" -lt ${#T_PID[@]} ]; do
      [ "${T_PID[$i]}" = "$pid" ] && {
        title="${T_TITLE[$i]}"; sid="${T_SID[$i]}"; prompt="${T_PROMPT[$i]}"; break
      }
      i=$((i + 1))
    done
    # Fall back to the launcher's @claude_title (dir#N), then the dir basename.
    # Both ride along on the live tmux read above, so a cached empty title still
    # renders correctly.
    [ -z "$title" ] && title="$ctitle"
    [ -z "$title" ] && title="${path##*/}"

    # Label field is 7 visible columns wide in every arm; the icon glyph and the
    # reset both sit outside it, so pad to 7 or the age column shifts.
    case "$state" in
    waiting)    icon=$'\033[33m●\033[0m waiting' rank=0 ;; # yellow - needs input
    idle)       icon=$'\033[32m●\033[0m idle   ' rank=1 ;; # green  - done, your turn
    background) icon=$'\033[36m◐\033[0m bg     ' rank=2 ;; # cyan   - answered you; a shell or agent is still out
    working)    icon=$'\033[31m●\033[0m working' rank=4 ;; # red    - busy, leave it
    *)          icon=$'\033[90m●\033[0m   ?    ' rank=3 ;; # grey   - unknown (no hook yet)
    esac
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t session \t icon \t age \t title(padded) \t path. Title is space-
    # padded (not tab) so fzf's 8-col tabstop doesn't jump the path column; 44 fits
    # the longest name. Padded by pad_display, NOT printf's %-44s — that pads by
    # bytes and misaligns any CJK title. rank asc, then age asc (just-finished
    # floats to group top).
    # Field 9 (sessionId) is for web-server.js to locate the transcript; fzf renders
    # only fields 3..6, so it never shows up in the picker itself.
    #
    # Field 8 is the preview notice, empty for a live pane. Built here rather than
    # in the preview because the clocks and `now` are already in hand; see
    # PREVIEW_CMD. A session with no timestamp is treated as live — better a wasted
    # capture than a silently blank preview.
    #
    # Aged on @claude_state_at, NOT #{window_activity}. Activity means the pane
    # repainted, and Claude's TUI repaints its context/reset line every couple of
    # minutes while doing nothing at all: measured on this list, four sessions whose
    # last real turn was 4h, 18h, 5d and 12d ago all showed activity 2-15 minutes
    # old and so stayed live, which is exactly backwards. @claude_state_at moves
    # only when a hook fires, i.e. on a real turn boundary.
    #
    # working and waiting are never frozen by AGE, for the same reason: a long
    # autonomous run holds `working` with a stale stamp and is the one session you
    # open the picker to watch, and a `waiting` pane is asking you something.
    # `never` overrides even that — see the option comment.
    frozen=''; frozen_rows=0
    if [ "$preview_max_age" -lt 0 ] ||
      { [ "$preview_max_age" -gt 0 ] && [ -n "$at" ] &&
        [ "$state" != working ] && [ "$state" != waiting ] &&
        [ $((now - at)) -gt "$preview_max_age" ]; }; then
      if [ -n "$at" ]; then human_age $((now - at)); idle_for="$HUMAN"; else idle_for='?'; fi
      if [ "$preview_max_age" -lt 0 ]; then HUMAN=never; else human_age "$preview_max_age"; fi
      # Rows are newline delimited, so the notice carries literal \n and the
      # preview expands them with printf %b. Fixed block width: the preview is
      # ~168 columns, so wrapping to NOTICE_W keeps every line inside it and makes
      # the centring offset a constant the preview can compute without measuring
      # anything.
      frozen="⏸  pane preview off · last turn $idle_for ago"
      frozen_rows=1
      if [ -n "$prompt" ]; then
        wrap_text "$prompt" $((NOTICE_W - 2))
        frozen="$frozen\\n\\nyour last prompt:"
        frozen="$frozen\\n\\n  ${WRAPPED//\\n/\\n  }"
        frozen_rows=$((frozen_rows + 4))
        # One row per \n added by the wrap.
        line="${WRAPPED}"
        while [ "${line#*\\n}" != "$line" ]; do
          line="${line#*\\n}"
          frozen_rows=$((frozen_rows + 1))
        done
      fi
      frozen="$frozen\\n\\nctrl-g: live pane · ctrl-o: back  ·  @claude_preview_max_age = $HUMAN"
      frozen_rows=$((frozen_rows + 2))
    fi
    pad_display "$title" 44
    # git 열은 state.sh 가 훅에서 채운 @claude_git 을 그대로 쓴다 — picker 안에서
    # git 을 돌리면 세션 19개에 200ms 라 ctrl-x reload 마다 눈에 띈다.
    #
    # 다만 훅은 턴 경계에서만 돈다. 되살렸지만 아직 한 마디도 안 한 세션은 값이
    # 없어서, repo 안에 있어도 계속 비어 보인다. 미설정일 때만 여기서 한 번 재고
    # 옵션에 남긴다 — 세션당 1회고 그 뒤로는 위 경로로 공짜다. state.sh 가 repo
    # 아닌 곳에 "-" 를 쓰므로 「아직 안 잼」과 「repo 아님」이 구분된다.
    # 훅이 아직 안 돈 세션은 값이 없다. 여기서 재되 렌더당 GIT_FILL_MAX 개까지만
    # 한다.
    #
    # 전부 한 번에 재면 12 세션에 700ms 가 걸리고, `load` 바인딩의 reload 는 그
    # 동안 목록을 비워 두므로 세션이 통째로 사라졌다 나타난다 (실측 콜드 700ms
    # vs 웜 40ms). reload-sync 로 바꾸거나 sleep 을 앞에 두는 우회는 둘 다 이미
    # 시도했다 되돌린 것이다 — 위 `load` 주석 참조. 그래서 명령을 느리게 만들지
    # 않는 쪽으로 푼다: 몇 개씩 채우면 두어 번의 새로고침 만에 전부 차고, 한 번의
    # 렌더가 늘어나는 폭은 40ms 남짓이다.
    if [ -z "$gitcol" ] && [ "$FILLED" -lt "$GIT_FILL_MAX" ]; then
      FILLED=$((FILLED + 1))
      # status --porcelain -b 한 번으로 브랜치·ahead·더티를 다 얻는다. 예전에는
      # rev-parse + status + rev-list 로 세 번 돌았다 (세션당 70ms -> 40ms).
      gst=$(git -C "$path" status --porcelain -b 2>/dev/null)
      if [ -n "$gst" ]; then
        ghead=${gst%%$'\n'*}                       # "## feat/x...origin/feat/x [ahead 2]"
        gbr=${ghead#\#\# }; gbr=${gbr%%...*}
        # detached HEAD 는 "## HEAD (no branch)" 로 나온다. 예전 rev-parse
        # --abbrev-ref 는 "HEAD" 만 줬고, 괄호까지 두면 22 폭을 다 먹는다.
        gbr=${gbr%% *}
        gahead=''
        case "$ghead" in *'[ahead '*) gahead="${ghead#*\[ahead }"; gahead="${gahead%%[],]*}" ;; esac
        gdirty=$(printf '%s\n' "$gst" | grep -vc '^##')
        gitcol="$gbr"
        [ "${gdirty:-0}" -gt 0 ] && gitcol="$gitcol *$gdirty"
        [ -n "$gahead" ] && gitcol="$gitcol ^$gahead"

        # rev-parse 도 두 값을 한 번에 받는다.
        grp=$(git -C "$path" rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null)
        gtop=${grp%%$'\n'*}; gcmn=${grp##*$'\n'}; gmain=${gcmn%/.git}
        if [ -n "$gtop" ] && [ "$gtop" != "$gmain" ]; then
          linkcol=">$gmain"
        else
          gw=$(git -C "$path" worktree list 2>/dev/null | grep -c '')
          if [ "${gw:-0}" -gt 1 ]; then linkcol="+$((gw - 1))wt"; else linkcol='-'; fi
        fi
      else
        gitcol='-'; linkcol='-'
      fi
      tmux set-option -t "$s" @claude_git "$gitcol" 2>/dev/null
      tmux set-option -t "$s" @claude_link "$linkcol" 2>/dev/null
    fi
    # 표시는 마커(*N ^N)만 남긴다. 브랜치는 경로 열의 워크트리 이름과 겹친다 —
    # 2026-09-03 실측에서 값이 있던 3행이 3행 다 겹쳤고, 나머지 11행은 비어 있었다.
    # state.sh 의 같은 자리 주석이 이미 "*N·^N 은 경로에 없는 정보"라고 적어 뒀다.
    # @claude_git 에는 브랜치를 그대로 저장한다 — 저장값을 바꾸면 state.sh 도
    # 같이 고쳐야 하고, 브랜치가 필요해지는 날 되살릴 데가 없어진다.
    case "$gitcol" in
      *' '*) gitmark="${gitcol#* }" ;;   # 브랜치 뒤에 붙은 마커만
      *)     gitmark='.' ;;              # 브랜치뿐(깨끗함) 또는 repo 아님
    esac
    # 포크는 parent 열을 워크트리 연결과 나눠 쓴다. 한 세션이 둘 다일 수는 있지만
    # (워크트리 안에서 포크) 드물고, 그때는 포크 쪽이 더 알기 어려운 사실이라 이긴다.
    #
    # 이름과 표시를 띄어 둔다. 붙이면 "(f)" 가 이름의 일부처럼 읽히는데, 세션
    # 제목에 실제로 괄호가 들어갈 수 있어서(tnt(old)) 더 그렇다.
    #
    # 값은 web-server 가 @claude_fork_of 에 써 준다 — 판정에 transcript 를 읽어야
    # 해서 picker 에서 하면 1.2초가 든다. 웹서버가 안 떠 있으면 이 열이 비어 있을
    # 뿐 깨지지 않는다.
    #
    # 지연 채움 뒤에 둔다. 그 블록이 linkcol 을 덮어쓰므로 앞에 두면 포크 표시가
    # 사라진다.
    [ -n "$forkcol" ] && linkcol="$forkcol (f)"
    pad_display "$gitmark" 6; GITCOL="$PADDED"
    pad_display "$title" 44
    printf '%s\t%s\t%s\t%5s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$s" "$icon" "$ago" "$PADDED" "$GITCOL" "$linkcol" "$path" "${path/#$HOME/~}" "$sid" "$frozen" "$frozen_rows"
  done | LC_ALL=C sort -t$'\t' -k1,1n -k4,4n | resolve_links
}

# 링크 열의 ">/abs/path" 를 그 경로를 쥔 세션의 제목으로 바꾼다.
#
# 2차 통과인 이유: 메인 repo 를 쥔 세션이 목록 어디에 있는지는 전 행을 다 읽어야
# 안다. 훅에서는 아예 불가능하다 — 훅은 자기 세션만 본다.
#
# awk 가 아니라 bash 인 이유는 폭이다. 링크 값은 세션 제목이라 한글이 섞이고,
# awk 는 문자 수만 세서 한글 한 자를 1칸으로 잡는다 — 제목이 한글이면 링크 열이
# 오른쪽으로 밀려 경로 열이 행마다 다른 자리에서 시작한다. pad_display 가 바이트
# 차이로 표시 폭을 재는 그 함수다.
#
# 필드: 1=rank 2=session 3=icon 4=age 5=title 6=git 7=link 8=abs경로 9=표시경로
#       10=sid 11=notice 12=notice행수. 8번(절대경로)은 여기서만 쓰고 지운다.
resolve_links() {
  local all row f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
  all="$(cat)"

  # 경로 -> 제목, 그리고 tmux 세션명 -> 제목. 제목은 5번 열이라 이미 44 폭으로
  # 패딩돼 있어 꼬리 공백을 뗀다.
  local owners='' names='' t
  while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12; do
    t="${f5%"${f5##*[![:space:]]}"}"
    [ -n "$f2" ] && names="$names$f2"$'\037'"$t"$'\n'
    [ -n "$f8" ] || continue
    owners="$owners$f8"$'\037'"$t"$'\n'
  done <<<"$all"

  # orch 큐의 parent — `orch add` 를 돌린 tmux 세션이다. 경로 대조만으로는 거의
  # 항상 실패한다: dispatcher 는 dispatch 루트(~/plab)에 앉아 있지 개별 repo
  # 디렉터리에 있지 않아서, 메인 repo 경로를 cwd 로 쥔 세션이 아예 없다.
  # 2026-09-03 실측 — 그래서 링크 열이 전부 repo 이름(new-plab-front,
  # pf-policy-bot)으로 떨어져 있었다. 큐가 유일하게 맞는 출처다.
  # 태스크 파일이 지워지면(orch rm) 이 값도 사라지므로 아래 경로 대조가 대안으로
  # 남는다.
  local parents
  parents=$(LC_ALL=C awk '
    function val(s) { sub(/^[^:]*:[ \t]*"/, "", s); sub(/"[ \t]*,?[ \t]*$/, "", s); return s }
    { f=FILENAME
      if (match($0, /"session"[ \t]*:[ \t]*"[^"]*"/)) S[f]=val(substr($0,RSTART,RLENGTH))
      if (match($0, /"parent"[ \t]*:[ \t]*"[^"]*"/))  P[f]=val(substr($0,RSTART,RLENGTH)) }
    END { for (f in S) if (S[f] != "" && (f in P) && P[f] != "") printf "%s\037%s\n", S[f], P[f] }
  ' "$HOME"/.claude/orch/queue/task-*.json 2>/dev/null)

  while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12; do
    case "$f7" in
      '>'*)
        local m="${f7#>}" hit='' pname='' op ot
        # 1순위 — orch 가 기록한 부모 세션. 이 열이 답해야 하는 것이 그것이다.
        while IFS=$'\037' read -r op ot; do
          [ "$op" = "$f2" ] && { pname="$ot"; break; }
        done <<<"$parents"
        if [ -n "$pname" ]; then
          while IFS=$'\037' read -r op ot; do
            [ "$op" = "$pname" ] && { hit="$ot"; break; }
          done <<<"$names"
          # 부모 세션이 이미 죽었으면 tmux 이름이라도 보여준다
          [ -z "$hit" ] && hit="$pname"
        fi
        # 2순위 — 메인 repo 를 cwd 로 쥔 세션. 그런 세션이 있을 때만 맞는다.
        if [ -z "$hit" ]; then
          while IFS=$'\037' read -r op ot; do
            [ "$op" = "$m" ] && { hit="$ot"; break; }
          done <<<"$owners"
        fi
        # 3순위 — repo 이름. "메인 세션 없음" 은 자리만 차지하고 어느 repo 인지
        # 못 알려준다 — 이름이면 최소한 그건 답한다.
        f7="${hit:-${m##*/}}"
        ;;
      ''|'-') f7='.' ;;
    esac
    pad_display "$f7" 30
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" "$PADDED" "$f9" "$f10" "$f11" "$f12"
  done <<<"$all"
}

[ "${1:-}" = '--list' ] && {
  # `touch ~/.claude/picker-debug` 로 켜는 계측. reload 는 목록을 비우고 명령을
  # 기다리므로, 행이 사라져 보인다는 신고가 오면 알아야 할 것은 두 가지뿐이다 —
  # 이 호출이 얼마나 걸렸나, 그리고 몇 행을 냈나. state.sh 의 state-debug 와 같은
  # 방식이라 평소에는 stat 한 번 값만 든다.
  # 소요 시간은 안 적는다. bash 3.2 에는 EPOCHREALTIME 이 없어서 밀리초를 재려면
  # 포크가 하나 더 드는데, 재려는 대상이 50ms 짜리라 계측이 대상을 밀어낸다.
  # 여기서 필요한 것은 「이 호출이 몇 행을 냈나」 하나다.
  if [ -e "$HOME/.claude/picker-debug" ]; then
    __out=$(emit_rows)
    printf '%s  rows=%s\n' "$(date '+%H:%M:%S')" "$(printf '%s' "$__out" | grep -c '')" \
      >> "$HOME/.claude/picker-debug.log"
    printf '%s\n' "$__out"
    exit 0
  fi
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
# Open on the session you were last inside rather than at the top of the list.
# @claude_last_session is maintained by record-last.sh off tmux's client-attached
# hook, so it survives however you left — picker, prefix+y, or a plain detach.
#
# The rows are materialised here instead of being piped straight into fzf because
# the cursor position has to be counted before fzf starts. `start` runs the action
# before anything has been read, so the list is handed over with --sync; without
# it pos() lands on an empty list and does nothing.
#
# A stale name (session since killed) simply never matches and the picker opens at
# the top, which is the old behaviour.
rows=$(emit_rows)
[ -z "$rows" ] && exit 0
last=$(tmux show-option -gqv @claude_last_session 2>/dev/null)
start_pos=0
if [ -n "$last" ]; then
  n=0
  while IFS=$'\t' read -r _ name _; do
    n=$((n + 1))
    [ "$name" = "$last" ] && { start_pos=$n; break; }
  done <<<"$rows"
fi
pos_opt=()
[ "$start_pos" -gt 0 ] && pos_opt=(--sync --bind="start:pos($start_pos)")

# 열 제목. 행과 같은 폭·같은 탭 구조로 만들어야 자리가 맞는다 — 상태 칸은
# "● waiting" 9칸, 나이는 %5s 우측 정렬이라 행의 printf 와 똑같이 찍는다.
pad_display 'state' 9;    H_ST="$PADDED"
pad_display 'session' 44; H_SE="$PADDED"
pad_display 'git' 6;      H_GI="$PADDED"
pad_display 'parent' 30;  H_PA="$PADDED"
# 굵게로 안내 문구와 가른다. fzf 는 --ansi 가 켜져 있어 --header 안의 이스케이프를
# 그대로 그린다. 앰버(256색 179) — 안내 문구의 흐린 청회색(109)과 색상이 갈리고,
# 행의 상태 색(초록 idle · 분홍 working)과도 안 겹친다. 바꾸려면 이 코드만 고친다.
HDR_COLS=$(printf '\033[1;38;5;179m%s\t%5s\t%s\t%s\t%s\t%s\033[0m' \
  "$H_ST" 'age' "$H_SE" "$H_GI" "$H_PA" 'path')

# @claude_fzf_options(~/.tmux.conf)의 --header 가 extra_opts 로 뒤에 붙어 스크립트의
# --header 를 덮는다 — fzf 는 마지막 --header 를 쓴다. 그래서 그 값을 꺼내 첫 줄로
# 삼고 열 제목을 아래에 붙여, 맨 끝에 한 번 더 준다. 폭은 이 스크립트가 정하므로
# 열 제목은 여기 있어야 하고, 안내 문구는 사용자 설정이 이긴다.
HDR_TEXT='Claude sessions · enter: jump · ctrl-x: kill  (rename via /rename in-session)'
_i=0
while [ "$_i" -lt "${#extra_opts[@]}" ]; do
  case "${extra_opts[$_i]}" in
    --header)   HDR_TEXT="${extra_opts[$((_i+1))]:-$HDR_TEXT}" ;;
    --header=*) HDR_TEXT="${extra_opts[$_i]#--header=}" ;;
  esac
  _i=$((_i + 1))
done

sel=$(printf '%s\n' "$rows" | fzf --ansi --delimiter='\t' --with-nth=3,4,5,6,7,8 \
  --reverse --cycle \
  --preview="$PREVIEW_CMD" --preview-window='up,70%,follow' \
	--bind="load:reload($self --list; sleep 2)" \
  --bind="ctrl-x:execute-silent(tmux kill-session -t {2})+reload($self --list)" \
  --bind="ctrl-g:change-preview($PANE_CMD)" \
  --bind="ctrl-o:change-preview($PREVIEW_CMD)" \
  ${pos_opt[@]+"${pos_opt[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"} \
  --header="$HDR_TEXT
$HDR_COLS")

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
