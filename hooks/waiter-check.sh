#!/usr/bin/env bash
# waiter-check.sh — Claude Code hook for SessionStart and UserPromptSubmit.
# Reads the hook JSON from stdin, finds this session in the seat registry and prints a one-line banner when its waiter
# is missing or has ended, or a line saying it cannot tell. Silent when the waiter is alive (same pid and start time).
# Anything printed on stdout reaches the model as context.
# a bad warroom.env must not block the prompt (exit 2 would): see WR_CONFIG_EXIT in bin/_common.sh
# shellcheck disable=SC2034
WR_CONFIG_EXIT=1
case $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac
HERE=$(cd -P "$_d" && pwd) || exit 1
. "$HERE/../bin/_common.sh" || exit 1
rowfail() { echo "waiter-check: could not read this session's row in the seat registry" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
IN=$(cat) || { echo "waiter-check: could not read the hook input" >&2; exit 1; }
SID=$(printf '%s' "$IN" | python3 -I -S -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null) || { echo "waiter-check: python3 could not read the hook input as JSON" >&2; exit 1; }
[ -n "$SID" ] || exit 0
BIN=$(cd -P "$HERE/../bin" && pwd) || exit 1
WAIT=$(printf '%q' "$BIN/waiter.sh") || { echo "waiter-check: cannot quote the path of the waiter" >&2; exit 1; }      # printed commands are shell-quoted: a path may hold spaces
REG="$W/seats.tsv"; wr_create "$REG" || { echo "waiter-check: cannot create the seat registry $REG" >&2; exit 1; }
# the registry is read whole before anything is judged: a failed read is said so and never turned into "not armed" or a stale row
rows=$(wr_registry_read "$REG") || { echo "waiter-check: the seat registry $REG could not be read, so this hook cannot tell whether your waiter runs" >&2; exit 1; }
row=$( set -o pipefail; printf '%s\n' "$rows" | awk -F'\t' -v s="$SID" '$1==s' | tail -1 ) || { echo "waiter-check: could not look up this session in the seat registry" >&2; exit 1; }
if [ -n "$row" ]; then
  seat=$(wr_col 2 "$row") || rowfail
  pid=$(wr_col 3 "$row") || rowfail
  started=$(wr_col 5 "$row") || rowfail
  cols=$(wr_ncols "$row") || rowfail
  [ "$seat" = NONE ] && exit 0
  wr_seat_ok "$seat" || { echo "unknown seat in registry" >&2; exit 0; }       # registry rows are data: a seat that is not in SEATS is not trusted
  # the waiter itself: same pid and same start time (a reused pid is not this waiter). A row with an empty start time and a
  # live pid is "cannot tell", never silent; only an old four-column row is judged by the pid alone.
  st=$(wr_rowproc "$pid" "$started" "$cols") || { echo "waiter-check: could not judge the waiter process (pid $pid)" >&2; exit 1; }
  case "$st" in
    alive) exit 0 ;;
    unknown) echo "[WAITER UNCHECKED] the start time of your $seat waiter (pid $pid) is not recorded or cannot be read (ps failed), so this hook cannot tell whether it still runs. If no waiter job is running in this session, re-arm it as a background job: bash $WAIT $seat $(printf '%q' "$SID")"; exit 0 ;;
    dead) ;;
    *) echo "waiter-check: unexpected answer '$st' for the waiter process (pid $pid)" >&2; exit 1 ;;
  esac
  echo "[WAITER ENDED] your $seat waiter (pid $pid) fired or died. Act on any '@$seat ACTION' line on the board, then re-arm it now as a background job: bash $WAIT $seat $(printf '%q' "$SID")"
  exit 0
fi
echo "[WAITER NOT ARMED] this session has no board trigger, so nothing wakes it when a line says '@<seat> ACTION'. First action, before other work, as a background job: bash $WAIT <one of: $SEATS> $(printf '%q' "$SID")   (or: waiter.sh NONE $(printf '%q' "$SID") to opt out)"
