#!/usr/bin/env bash
# board-guard.sh — Claude Code hook for UserPromptSubmit. Names a seat that has been silent too long and has no
# registered job running, with one "@SEAT ACTION:" line on the board, at most once per silence.
# Silent means: no board line stamped with its name for WARROOM_IDLE_MIN minutes (default 30).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../bin/_common.sh"
case "${1:-}" in -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cat >/dev/null 2>&1
IDLE=${WARROOM_IDLE_MIN:-30}; h=$(date +%H); m=$(date +%M)
nowmin=$((10#$h*60+10#$m))
for seat in $SEATS; do
  hit=$(grep -nE "^\[[0-9]{2}:[0-9]{2} · ${seat}\]" "$BOARD_FILE" | tail -1); lineno=${hit%%:*}; line=${hit#*:}
  [ -n "$line" ] || continue                                   # never posted: not started yet
  hm=${line:1:5}; lastmin=$((10#${hm%%:*}*60+10#${hm##*:})); age=$(( (nowmin-lastmin+1440) % 1440 ))
  [ "$age" -ge "$IDLE" ] || continue
  grep -qE "	${seat}$" "$W/pids.tsv" 2>/dev/null && continue    # it owns a running job: working, not idle
  mark="$W/.guard-$seat"
  # once per silence: the mark holds the line number of the seat's last post; same number = already said it
  [ "$(cat "$mark" 2>/dev/null)" = "$lineno" ] && continue
  echo "$lineno" > "$mark"
  "$HERE/../bin/board.sh" post GUARD "@${seat} ACTION: no board post from you for ${age} min and no registered job. Take the next unclaimed card, or post what you are waiting on." >/dev/null
done
exit 0
