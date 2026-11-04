#!/usr/bin/env bash
# board-guard.sh — Claude Code hook for UserPromptSubmit. Names a seat that has been silent too long and has no
# registered job running, with one "@SEAT ACTION:" line on the board, at most once per silence.
# Silent means: no board line stamped with its name for WARROOM_IDLE_MIN minutes (default 30).
# A seat that owns a registered job whose process is still running is working, not idle. "Still running" means the same
# process: when the ledger recorded a start time, a reused pid that started at another time does not count.
# "At most once per silence": the mark remembers which post it spoke about (board generation, line number and the line
# itself), so a replaced board, or a new post that lands on the same line number, starts a new silence.
# a bad warroom.env must not block the prompt (exit 2 would): see WR_CONFIG_EXIT in bin/_common.sh
# shellcheck disable=SC2034
WR_CONFIG_EXIT=1
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../bin/_common.sh"; . "$HERE/../bin/_cursor.sh"
case "${1:-}" in -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cat >/dev/null 2>&1
IDLE=${WARROOM_IDLE_MIN:-30}; h=$(date +%H); m=$(date +%M); TAB="$(printf '\t')"
nowmin=$((10#$h*60+10#$m))
for seat in $SEATS; do
  hit=$(grep -nE "^\[[0-9]{2}:[0-9]{2} · ${seat}\]" "$BOARD_FILE" | tail -1); lineno=${hit%%:*}; line=${hit#*:}
  [ -n "$line" ] || continue                                   # never posted: not started yet
  hm=${line:1:5}; lastmin=$((10#${hm%%:*}*60+10#${hm##*:})); age=$(( (nowmin-lastmin+1440) % 1440 ))
  [ "$age" -ge "$IDLE" ] || continue
  # a seat that owns a registered job whose process is still alive is working (pids.tsv: label pid owner started)
  busy=0
  while IFS="$TAB" read -r _l jp _o js; do
    [ -n "$jp" ] || continue
    kill -0 "$jp" 2>/dev/null || continue
    # same process? (a recorded start time must match; a row without one is judged by the pid alone)
    [ -z "$js" ] || [ "$(ps -o lstart= -p "$jp" 2>/dev/null | tr -s ' ' | sed 's/^ //')" = "$js" ] && busy=1
  done < <(awk -F'\t' -v s="$seat" '$3==s' "$W/pids.tsv" 2>/dev/null)
  [ "$busy" = 0 ] || continue
  mark="$W/.guard-$seat"
  # once per silence: the mark holds the board generation, line number and checksum of the seat's last post; the same
  # three = already said it.
  # Check, post and mark happen under one lock, so two prompts at the same moment say it once; the mark is written
  # only after the post succeeded, so a failed post is tried again at the next prompt.
  wr_lock "$mark" || continue
  here="$(wr_generation "$BOARD_FILE") $lineno $(printf '%s\n' "$line" | wr_sum)"
  if [ "$(cat "$mark" 2>/dev/null)" != "$here" ] &&
     "$HERE/../bin/board.sh" post GUARD "@${seat} ACTION: no board post from you for ${age} min and no registered job. Take the next unclaimed card, or post what you are waiting on." >/dev/null 2>&1; then
    printf '%s\n' "$here" > "$mark.tmp.$$" && mv "$mark.tmp.$$" "$mark"
  fi
  wr_unlock "$mark"
done
exit 0
