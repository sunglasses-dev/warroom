#!/usr/bin/env bash
# waiter-check.sh — Claude Code hook for SessionStart and UserPromptSubmit.
# Reads the hook JSON from stdin, finds this session in the seat registry and prints a one-line banner when its waiter
# is missing or has ended. Silent when the waiter is alive. Anything printed on stdout reaches the model as context.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/../bin/_common.sh"
case "${1:-}" in -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
IN=$(cat 2>/dev/null)
SID=$(printf '%s' "$IN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
[ -n "$SID" ] || exit 0
REG="$W/seats.tsv"; touch "$REG"
row=$(awk -F'\t' -v s="$SID" '$1==s' "$REG" | tail -1)
if [ -n "$row" ]; then
  seat=$(printf '%s' "$row" | cut -f2); pid=$(printf '%s' "$row" | cut -f3)
  [ "$seat" = NONE ] && exit 0
  kill -0 "$pid" 2>/dev/null && exit 0
  echo "[WAITER ENDED] your $seat waiter (pid $pid) fired or died. Act on any '@$seat ACTION' line on the board, then re-arm it now as a background job: bash $HERE/../bin/waiter.sh $seat $SID"
  exit 0
fi
echo "[WAITER NOT ARMED] this session has no board trigger, so nothing wakes it when a line says '@<seat> ACTION'. First action, before other work, as a background job: bash $HERE/../bin/waiter.sh <one of: $SEATS> $SID   (or: waiter.sh NONE $SID to opt out)"
