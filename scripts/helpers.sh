#!/usr/bin/env bash
# Shared helpers for tmux-claude-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-8
}

# popup_cells <option> <client cells>
# A size option as cells: a percentage of the client (integer division, as tmux
# does), or a cell count as given.
popup_cells() {
  case "$1" in
    *%) echo $(( $2 * ${1%\%} / 100 )) ;;
    *)  echo "$1" ;;
  esac
}

# popup_geometry <width option> <height option> [client]
# Echoes "w h x y" for display-popup -w -h -x -y: the size the options ask for,
# centred in the rows the status line leaves. tmux's own centre (-x C -y C) is not
# even: it reads -y as the line below the popup, floors twice and counts the status
# line, so a 95% popup on 210x94 sat 1 row from the top and 4 from the bottom. A
# size that would leave an odd margin is made one cell smaller, so both sides match.
# The client is the outer one the popup opens on; without one, the current client.
popup_geometry() {
  local cw ch
  if [ -n "${3:-}" ]; then
    # display -p -c resolves client_* to the invoking pane's client, which inside a
    # popup is the popup: look the client up by name instead
    read -r cw ch < <(tmux list-clients -F '#{client_name} #{client_width} #{client_height}' 2>/dev/null |
      awk -v c="$3" '$1 == c { print $2, $3; exit }')
  else
    read -r cw ch < <(tmux display-message -p '#{client_width} #{client_height}' 2>/dev/null)
  fi
  if [ -z "${cw:-}" ] || [ -z "${ch:-}" ]; then
    echo "$1" "$2" C C
    return
  fi
  local st top=0 area w h
  st="$(tmux show -gv status 2>/dev/null)"
  case "$st" in off) st=0 ;; on | '' | *[!0-9]*) st=1 ;; esac
  [ "$(tmux show -gv status-position 2>/dev/null)" = top ] && top=$st
  area=$(( ch - st ))
  w=$(popup_cells "$1" "$cw")
  h=$(popup_cells "$2" "$ch")
  [ "$w" -gt "$cw" ] && w=$cw
  [ "$h" -gt "$area" ] && h=$area
  [ $(( (cw - w) % 2 )) -eq 1 ] && w=$(( w - 1 ))
  [ $(( (area - h) % 2 )) -eq 1 ] && h=$(( h - 1 ))
  # -y names the line below the popup: tmux subtracts the height from it
  echo "$w" "$h" $(( (cw - w) / 2 )) $(( top + (area - h) / 2 + h ))
}
