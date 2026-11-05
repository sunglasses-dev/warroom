#!/usr/bin/env bash
# board.sh — the board is one text file; every seat appends stamped lines and reads what is new.
#   board.sh post SEAT "text"      append "[HH:MM · SEAT] text" (extra lines are indented two spaces)
#   board.sh tail SEAT             print the lines added since SEAT last ran tail, then move its anchor
#                                  (a replaced or truncated board is printed again from its start)
#   board.sh read [N]              print the last N lines (default 20), no anchor change
#   board.sh path                  print the board file path
# Grammar: a post wakes a seat only when its first line starts with "@SEAT ACTION:" (see docs/PROTOCOL.md).
# Posts are limited to 10 lines. WARROOM_LONG=1 lifts the limit for one call.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"; . "$HERE/_cursor.sh"
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
    seat=${2:-}; [ -n "$seat" ] || { echo "usage: board.sh tail SEAT" >&2; exit 2; }
    wr_seat_arg "$seat"; a="$W/.anchor-$seat"          # a seat becomes part of a path: it must be in SEATS before any lock or file
    wr_lock "$a" || { echo "could not lock the anchor for $seat" >&2; exit 1; }     # two tails never write an older line over a newer one
    g=$(wr_generation "$BOARD_FILE"); n=$(wc -l < "$BOARD_FILE" | tr -d ' ')
    last=$(wr_cursor_get "$a" "$BOARD_FILE" 31536000); [ "$last" = none ] && last=0
    # print what is new; the anchor remembers where, and a checksum of everything, it read
    chunk="$a.chunk.$$"; snap="$a.snap.$$"
    # one read: the lines and their sum are the same bytes; scratch files that cannot be written end the read before anything is marked
    if ! { head -n "$n" "$BOARD_FILE" > "$snap" && sum=$(wr_sumstdin < "$snap") && tail -n "$((n-last))" "$snap" > "$chunk"; }; then
      echo "could not write a scratch file for $seat in $W (full or read-only?): nothing marked as read" >&2
      rm -f "$chunk" "$snap"; wr_unlock "$a"; exit 1
    fi
    # print first, then save the position: a line is marked as read only after it was written out. If the output fails
    # (closed pipe, full disk) the anchor stays, exit 1, and the lines come again. If only the anchor cannot be saved the
    # lines were printed and come once more (at-least-once, never lost); the exit code says so.
    if ! cat "$chunk"; then echo "could not write the lines for $seat to the output: nothing marked as read" >&2; rc=1
    elif wr_cursor_put "$a" "$g" "$n" "$sum"; then rc=0
    else echo "could not save the read position of $seat ($a): the lines above were printed but NOT marked as read; they come again" >&2; rc=1; fi
    rm -f "$chunk" "$snap"; wr_unlock "$a"; exit "$rc" ;;
  read) n=${2:-20}; tail -n "$n" "$BOARD_FILE" ;;
  path) echo "$BOARD_FILE" ;;
  -h|--help|help|"") sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$cmd' (post|tail|read|path|--help)" >&2; exit 2 ;;
esac
