#!/usr/bin/env bash
# Status-bar badges for claude-* sessions, printed as one string so tmux's
# align=centre (see ~/.tmux.conf status-format[0]) centres whatever is present:
# one badge alone lands dead-centre, both land centred as a pair.
#
#   ⏳ N waiting   sessions blocked on you (AskUserQuestion / permission)
#   ✅ N done      sessions that handed back within the last DONE_WINDOW seconds
#
# Both badges skip sessions you are attached to: the prompt is already on your
# screen, so counting it tells you to go somewhere you already are. `waiting` skips
# on attachment ALONE, without the sticky @claude_done_seen treatment `done` gets
# below — a question you walked away from is still blocking, so it has to come back
# when you detach. A handback is an event you either saw or didn't; a block is a
# state that persists until you answer it.
#
# The `done` badge is the text counterpart of the web picker's throbbing dot
# (scripts/web/index.html DONE_PULSE_MS) and deliberately mirrors its rules:
#
#   - Same 300s window. Keep the two constants in step.
#   - Attaching IS the acknowledgement, and it STICKS. Merely skipping attached
#     sessions would let the badge come back the moment you detach, for a handback
#     you have already seen; the web clears its doneAt for the same reason. So an
#     attached session gets its handback instant copied to @claude_done_seen, and
#     a session whose @claude_state_at still matches that is done being announced.
#     The next handback writes a new @claude_state_at, which no longer matches —
#     storing the instant rather than a flag is what makes it self-clearing.
#   - Only the idle transition counts. The web also pulses working -> waiting and
#     working -> bg; the first already has its own badge above (counting it twice
#     would show one session in both), and the second is invisible from here —
#     entering bg leaves @claude_state at `working` and skips the timestamp
#     entirely (state.sh sets skip_stamp), so there is nothing to measure.
#
# @claude_state_at is stamped on real state TRANSITIONS only, which is exactly the
# handback instant. A session re-asserting the same state keeps its old timestamp,
# so a long working stretch cannot masquerade as a fresh handback.
# colour16, not black: the status bar is bg=green,fg=black, and iTerm2 draws bold
# text in bright colours by default — `fg=black,bold` would come out bright black
# (grey) on green, fainter than the plain text it was meant to strengthen. The
# bright remap only covers the basic 8 colours, so the 256-palette black is bold
# without being lightened. #[default] restores the bar style, attributes included.
set -uo pipefail

DONE_WINDOW=300

# Fields are | -separated, not space-separated: @claude_state_at is empty on a
# session that never transitioned, and awk's default splitting would collapse the
# gap and shift `attached` into the timestamp's place.
sessions=$(tmux list-sessions \
  -F '#{@claude_state}|#{@claude_state_at}|#{session_attached}|#{@claude_done_seen}|#{session_name}' \
  2>/dev/null)

# Record the acknowledgement. Status scripts run on every client's refresh, so this
# is the cheapest place to notice an attach — no extra tmux hook to wire, and a
# switch-client between two sessions is caught by the same sweep. The guard keeps
# it to one write per handback instead of one per refresh.
while IFS='|' read -r state at attached seen _name; do
  [ "$attached" = "1" ] && [ -n "$at" ] && [ "$at" != "$seen" ] &&
    tmux set-option -t "$_name" @claude_done_seen "$at"
done <<< "$sessions"

awk -F'|' -v now="$(date +%s)" -v win="$DONE_WINDOW" '
      $1 == "waiting" && $3 == 0 { w++ }
      # An empty $2 becomes 0, which is always outside the window. $2 == $4 means
      # this exact handback was already seen from an attached client.
      $1 == "idle" && $3 == 0 && $2 != $4 && now - ($2 + 0) < win { d++ }
      END {
        if (w) printf "#[fg=colour16,bold]⏳ %d waiting #[default]", w
        if (w && d) printf " "
        if (d) printf "#[fg=colour16,bold]✅ %d done #[default]", d
      }' <<< "$sessions"
exit 0
