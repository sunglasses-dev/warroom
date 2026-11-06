#!/usr/bin/env bash
# board-tail.sh — Claude Code hook for UserPromptSubmit. Prints how many board lines are new for this seat and shows the
# ones that name it. It does not move the seat's read anchor; `bin/board.sh tail SEAT` does that.
# a bad warroom.env must not block the prompt (exit 2 would): see WR_CONFIG_EXIT in bin/_common.sh
# shellcheck disable=SC2034
WR_CONFIG_EXIT=1
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
. "$HERE/../bin/_common.sh" || exit 1
. "$HERE/../bin/_cursor.sh" || exit 1
case "${1:-}" in -h|--help) sed -n -- '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
IN=$(cat) || { echo "board-tail: could not read the hook input" >&2; exit 1; }
SID=$(printf '%s' "$IN" | python3 -I -S -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null) || { echo "board-tail: python3 could not read the hook input as JSON" >&2; exit 1; }
[ -n "$SID" ] || exit 0
rows=$(wr_registry_read "$W/seats.tsv") || { echo "board-tail: could not read the seat registry $W/seats.tsv: no count shown" >&2; exit 1; }
seat=$( set -o pipefail; printf '%s\n' "$rows" | awk -F'\t' -v s="$SID" '$1==s {print $2}' | tail -1 ) || { echo "board-tail: could not look up this session in the seat registry: no count shown" >&2; exit 1; }
[ -n "$seat" ] && [ "$seat" != NONE ] || exit 0
wr_seat_ok "$seat" || exit 0          # a registry row is data: a seat outside SEATS never becomes the name of an anchor file
n=$(wr_lines "$BOARD_FILE") || { echo "board-tail: could not count the lines of the board $BOARD_FILE: no count shown" >&2; exit 1; }
last=$(wr_cursor_get "$W/.anchor-$seat" "$BOARD_FILE" 31536000) || { echo "board-tail: could not read the read position of seat $seat (or checksum the board $BOARD_FILE): no count shown" >&2; exit 1; }
[ "$last" = none ] && last=0
new=$((n-last)); [ "$new" -gt 0 ] || exit 0
echo "[BOARD] $new new line(s) since your last read. Read them with: bash $(printf '%q' "$(cd "$HERE/../bin" && pwd)/board.sh") tail $seat"
# the lines that name this seat: a view of the board, last in the script and followed by nothing that is written. A board with
# no such line is not an error (awk, unlike grep, exits 0 on no match), so a failing stage here is a real read error.
set -o pipefail
sed -n "$((last+1)),${n}p" "$BOARD_FILE" | awk -v a="@${seat} " 'index($0, a) || index($0, "@ALL ")' | tail -3 | cut -c1-300
