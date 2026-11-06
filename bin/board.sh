#!/usr/bin/env bash
# board.sh — the board is one text file; every seat appends stamped lines and reads what is new.
#   board.sh post SEAT "text"      append "[HH:MM · SEAT] text" (extra lines are indented two spaces)
#   board.sh tail SEAT             print the lines added since SEAT last ran tail, then move its anchor
#                                  (a replaced or truncated board is printed again from its start)
#   board.sh read [N]              print the last N lines (default 20), no anchor change
#   board.sh path                  print the board file path
# Grammar: a post wakes a seat only when its first line starts with "@SEAT ACTION:" (see docs/PROTOCOL.md).
# Posts are limited to 10 lines. WARROOM_LONG=1 lifts the limit for one call.
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
. "$HERE/_common.sh" || exit 1
. "$HERE/_cursor.sh" || exit 1
cmd=${1:-}
case "$cmd" in
  post)
    seat=${2:-}; text=${3:-}
    [ -n "$seat" ] && [ -n "$text" ] || { echo "usage: board.sh post SEAT \"text\"" >&2; exit 2; }
    if ! wr_seat_ok "$seat" && [ "$seat" != GUARD ]; then echo "unknown seat '$seat' (seats: $SEATS)" >&2; exit 2; fi
    n=$(printf '%s\n' "$text" | wr_lines /dev/stdin) || { echo "could not count the lines of the post: nothing posted" >&2; exit 1; }
    if [ "$n" -gt 10 ] && [ "${WARROOM_LONG:-0}" != 1 ]; then echo "post is $n lines; the limit is 10 (WARROOM_LONG=1 to override)" >&2; exit 2; fi
    stamp=$(wr_now) || { echo "could not read the clock: nothing posted" >&2; exit 1; }
    wr_hhmm "$stamp" || { echo "could not read the clock: nothing posted" >&2; exit 1; }
    first=1; out=""
    while IFS= read -r line || [ -n "$line" ]; do
      if [ $first = 1 ]; then out="[$stamp · $seat] $line"; first=0; else out="$out
  $line"; fi
    done <<EOT
$text
EOT
    wr_append "$out" ;;
  tail)
    seat=${2:-}; [ -n "$seat" ] || { echo "usage: board.sh tail SEAT" >&2; exit 2; }
    wr_seat_arg "$seat"; a="$W/.anchor-$seat"          # a seat becomes part of a path: it must be in SEATS before any lock or file
    wr_lock "$a" || { echo "could not lock the anchor for $seat" >&2; exit 1; }     # two tails never write an older line over a newer one
    g=$(wr_generation "$BOARD_FILE") || { echo "could not read the board $BOARD_FILE: nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    n=$(wr_lines "$BOARD_FILE") || { echo "could not count the lines of the board $BOARD_FILE: nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    last=$(wr_cursor_get "$a" "$BOARD_FILE" 31536000) || { echo "could not read the read position of seat $seat ($a), or checksum the board $BOARD_FILE: nothing marked as read. A damaged position file named above can be removed to start again at the end of the board." >&2; wr_unlock "$a"; exit 1; }
    [ "$last" = none ] && last=0
    # print what is new; the anchor remembers where, and a checksum of everything, it read. The two scratch files are temps
    # this call made (snap_t, chunk_t) and removes; a temp that cannot be removed is reported with its path.
    snap_t=""; chunk_t=""
    # one read: the lines and their sum are the same bytes; a scratch file or a sum that fails ends the read before anything is marked.
    # An empty board (n = 0) gets an empty snapshot without head -n 0, which macOS rejects.
    wr_temp "$a" || { echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    snap_t=$_WR_TMP
    wr_temp "$a" || { wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    chunk_t=$_WR_TMP
    if [ "$n" -gt 0 ]; then
      head -n "$n" "$BOARD_FILE" > "$snap_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    else
      : > "$snap_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    fi
    sum=$(wr_sumstdin < "$snap_t") || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    if [ "$((n-last))" -gt 0 ]; then
      tail -n "$((n-last))" "$snap_t" > "$chunk_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    else
      : > "$chunk_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "could not write a scratch file or checksum the board for $seat in $W (full or read-only?): nothing marked as read" >&2; wr_unlock "$a"; exit 1; }
    fi
    # print first, then save the position: a line is marked as read only after it was written out. If the output fails
    # (closed pipe, full disk) the anchor stays and the exit is 1; a retry can repeat lines the reader already got. If only
    # the anchor cannot be saved the lines were printed and a retry can show them again (at-least-once, not exactly once);
    # the exit code says so.
    cat "$chunk_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; wr_unlock "$a"; echo "could not write the lines for $seat to the output: not marked as read (a retry can repeat some of them)" >&2; exit 1; }
    wr_cursor_put "$a" "$g" "$n" "$sum" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; wr_unlock "$a"; echo "could not save the read position of $seat ($a): the lines above were printed but NOT marked as read; a retry shows them again" >&2; exit 1; }
    wr_drop "$chunk_t"; wr_drop "$snap_t"; wr_unlock "$a"; exit 0 ;;
  read) n=${2:-20}; tail -n "$n" "$BOARD_FILE" ;;
  path) echo "$BOARD_FILE" ;;
  -h|--help|help|"") sed -n -- '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$cmd' (post|tail|read|path|--help)" >&2; exit 2 ;;
esac
