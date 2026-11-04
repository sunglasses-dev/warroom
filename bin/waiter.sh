#!/usr/bin/env bash
# waiter.sh SEAT [SESSION_ID] — the mention waiter. Run it as a background job from the seat's own session.
# It sleeps (no model calls, no tokens) and exits the moment a NEW board line is addressed to the seat:
#   "@SEAT ACTION"  or  "@ALL ACTION"   (a plain "@SEAT" in prose does not wake anyone)
# The exit is the wake: the session that started the job is told the job finished and sees the line.
# Re-arm after every wake. SEAT=NONE opts a session out. One live session per seat: arming a taken seat is refused.
# Tuning (warroom.env): WARROOM_POLL seconds between checks (5), WARROOM_MIN_GAP seconds between two wakes (60).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
SEAT=$1; SID=${2:-unknown}; POLL=${WARROOM_POLL:-5}; GAP=${WARROOM_MIN_GAP:-60}
REG="$W/seats.tsv"; touch "$REG"; TAB="$(printf '\t')"
if [ "$SEAT" != NONE ] && ! wr_seat_ok "$SEAT"; then echo "unknown seat '$SEAT' (seats: $SEATS, or NONE)" >&2; exit 2; fi
if [ "$SEAT" != NONE ]; then
  holder=$(awk -F'\t' -v s="$SID" -v seat="$SEAT" '$2==seat && $1!=s {print $3}' "$REG" | tail -1)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "REFUSED: seat $SEAT is held by another live session (waiter pid $holder). Arm as NONE, or free the seat first." >&2; exit 1
  fi
fi
wr_lock "$REG" || exit 1
awk -F'\t' -v s="$SID" -v seat="$SEAT" '$1!=s && $2!=seat' "$REG" > "$REG.tmp.$$"
printf '%s\t%s\t%s\t%s\n' "$SID" "$SEAT" "$$" "$(wr_now)" >> "$REG.tmp.$$"; mv "$REG.tmp.$$" "$REG"; wr_unlock "$REG"
[ "$SEAT" = NONE ] && { echo "this session opted out of board triggers"; exit 0; }
FIRES="$W/.fires-$SEAT-$(date +%Y-%m-%d)"
PAT="@${SEAT} ACTION|@ALL ACTION"
base=$(wc -l < "$BOARD_FILE" | tr -d ' ')
# resume from the line count at the last wake today, so a line posted between the wake and the re-arm is not lost
lastn=$(tail -1 "$FIRES" 2>/dev/null | awk '{print $3}')
case "$lastn" in ''|*[!0-9]*) ;; *) [ "$lastn" -le "$base" ] && base=$lastn ;; esac
echo "armed $SEAT pid $$ at line $base $(date +%H:%M:%S)" >&2
pend=""
while :; do
  sleep "$POLL"
  grep -q "${TAB}${SEAT}${TAB}$$${TAB}" "$REG" 2>/dev/null || exit 0     # replaced by a newer arm: go quiet
  "$HERE/pids.sh" check >/dev/null 2>&1 || true
  n=$(wc -l < "$BOARD_FILE" | tr -d ' '); [ "$n" -lt "$base" ] && base=0
  if [ "$n" -gt "$base" ]; then
    new=$(sed -n "$((base+1)),${n}p" "$BOARD_FILE" | grep -E "$PAT" | grep -vE "^\[[0-9:]+ · ${SEAT}\]" || true)
    base=$n
    [ -n "$new" ] && pend="${pend:+$pend
}$new"
  fi
  if [ -n "$pend" ]; then
    if [ -s "$FIRES" ] && [ $(( $(date +%s) - $(wr_mtime "$FIRES") )) -lt "$GAP" ]; then continue; fi   # loop guard: held, not lost
    echo "$SEAT $(date +%H:%M:%S) $base" >> "$FIRES"
    echo "[WAKE -> $SEAT] a board line is addressed to you. Act on it, then re-arm: bash $HERE/waiter.sh $SEAT $SID (as a background job)."
    printf '%s\n' "$pend"
    exit 0
  fi
done
