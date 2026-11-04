#!/usr/bin/env bash
# board-guard.sh — Claude Code hook for UserPromptSubmit. Names a seat that has been silent too long and has no
# registered job running, with one "@SEAT ACTION:" line on the board, at most once per silence.
# Silent means: no board line stamped with its name for WARROOM_IDLE_MIN minutes (default 30).
# A seat that owns a registered job whose process is still running is working, not idle.
# a bad warroom.env must not block the prompt (exit 2 would): see WR_CONFIG_EXIT in bin/_common.sh
# shellcheck disable=SC2034
WR_CONFIG_EXIT=1
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../bin/_common.sh"
case "${1:-}" in -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cat >/dev/null 2>&1
IDLE=${WARROOM_IDLE_MIN:-30}; h=$(date +%H); m=$(date +%M)
nowmin=$((10#$h*60+10#$m))
for seat in $SEATS; do
  hit=$(grep -nE "^\[[0-9]{2}:[0-9]{2} · ${seat}\]" "$BOARD_FILE" | tail -1); lineno=${hit%%:*}; line=${hit#*:}
  [ -n "$line" ] || continue                                   # never posted: not started yet
  hm=${line:1:5}; lastmin=$((10#${hm%%:*}*60+10#${hm##*:})); age=$(( (nowmin-lastmin+1440) % 1440 ))
  [ "$age" -ge "$IDLE" ] || continue
  # a seat that owns a registered job whose process is still alive is working (pids.tsv: label pid owner started)
  busy=0
  for jp in $(awk -F'\t' -v s="$seat" '$3==s {print $2}' "$W/pids.tsv" 2>/dev/null); do
    kill -0 "$jp" 2>/dev/null && busy=1
  done
  [ "$busy" = 0 ] || continue
  mark="$W/.guard-$seat"
  # once per silence: the mark holds the line number of the seat's last post; same number = already said it.
  # Check, post and mark happen under one lock, so two prompts at the same moment say it once; the mark is written
  # only after the post succeeded, so a failed post is tried again at the next prompt.
  wr_lock "$mark" || continue
  if [ "$(cat "$mark" 2>/dev/null)" != "$lineno" ] &&
     "$HERE/../bin/board.sh" post GUARD "@${seat} ACTION: no board post from you for ${age} min and no registered job. Take the next unclaimed card, or post what you are waiting on." >/dev/null 2>&1; then
    echo "$lineno" > "$mark.tmp.$$" && mv "$mark.tmp.$$" "$mark"
  fi
  wr_unlock "$mark"
done
exit 0
