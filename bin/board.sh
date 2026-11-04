#!/usr/bin/env bash
# board.sh — the board is one text file; every seat appends stamped lines and reads what is new.
#   board.sh post SEAT "text"      append "[HH:MM · SEAT] text" (extra lines are indented two spaces)
#   board.sh tail SEAT             print the lines added since SEAT last ran tail, then move its anchor
#   board.sh read [N]              print the last N lines (default 20), no anchor change
#   board.sh path                  print the board file path
# Grammar: a line that should wake a seat starts with "@SEAT ACTION:" (see docs/PROTOCOL.md).
# Posts are limited to 10 lines. WARROOM_LONG=1 lifts the limit for one call.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
cmd=${1:-}
case "$cmd" in
  post)
    seat=${2:-}; text=${3:-}
    [ -n "$seat" ] && [ -n "$text" ] || { echo "usage: board.sh post SEAT \"text\"" >&2; exit 2; }
    if ! wr_seat_ok "$seat" && [ "$seat" != GUARD ]; then echo "unknown seat '$seat' (seats: $SEATS)" >&2; exit 2; fi
    n=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
    if [ "$n" -gt 10 ] && [ "${WARROOM_LONG:-0}" != 1 ]; then echo "post is $n lines; the limit is 10 (WARROOM_LONG=1 to override)" >&2; exit 2; fi
    first=1; out=""
    while IFS= read -r line || [ -n "$line" ]; do
      if [ $first = 1 ]; then out="[$(wr_now) · $seat] $line"; first=0; else out="$out
  $line"; fi
    done <<EOT
$text
EOT
    wr_append "$out" ;;
  tail)
    seat=${2:?usage: board.sh tail SEAT}; a="$W/.anchor-$seat"
    n=$(wc -l < "$BOARD_FILE" | tr -d ' '); last=$(cat "$a" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac; [ "$last" -gt "$n" ] && last=0
    sed -n "$((last+1)),${n}p" "$BOARD_FILE"; echo "$n" > "$a" ;;
  read) n=${2:-20}; tail -n "$n" "$BOARD_FILE" ;;
  path) echo "$BOARD_FILE" ;;
  -h|--help|help|"") sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$cmd' (post|tail|read|path|--help)" >&2; exit 2 ;;
esac
