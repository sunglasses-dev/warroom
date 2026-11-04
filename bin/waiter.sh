#!/usr/bin/env bash
# waiter.sh SEAT SESSION_ID — the mention waiter. Run it as a background job from the seat's own session.
# It sleeps (no model calls, no tokens) and exits the moment a NEW board post is addressed to the seat. A post wakes a seat
# only when its FIRST line, right after the "[HH:MM · AUTHOR]" stamp, starts with "@SEAT ACTION:" or "@ALL ACTION:" and
# the author is not the seat itself. Prose, "ACTIONABLE", a quoted directive and any later line of a post wake nobody.
# The exit is the wake: the session that started the job is told the job finished and sees the line. Re-arm after every wake.
# SEAT=NONE opts a session out. One live session per seat: arming a taken seat is refused (exit 1). SESSION_ID is required.
# A waiter replaced by a newer arm of the same seat stops with exit 3, so that is never mistaken for a wake (exit 0).
# Position: the last wake is saved in $WARROOM_DIR/.cursor-SEAT with the board's inode and first line. A re-arm within
# WARROOM_CURSOR_MAX_AGE seconds (86400) resumes there, also across midnight; a replaced or truncated board is read
# again from its start. The FIRST arm, or one after that age, starts at the end of the board and sees only what follows.
# Tuning (warroom.env): WARROOM_POLL seconds between checks (5), WARROOM_MIN_GAP seconds between two wakes (60).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"; . "$HERE/_cursor.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
SEAT=$1; SID=${2:-}; POLL=${WARROOM_POLL:-5}; GAP=${WARROOM_MIN_GAP:-60}; AGE=${WARROOM_CURSOR_MAX_AGE:-86400}
REG="$W/seats.tsv"; touch "$REG"; TAB="$(printf '\t')"
if [ "$SEAT" != NONE ] && ! wr_seat_ok "$SEAT"; then echo "unknown seat '$SEAT' (seats: $SEATS, or NONE)" >&2; exit 2; fi
case "$SID" in ''|unknown) echo "a session id is required: waiter.sh SEAT SESSION_ID (see README, quick start)" >&2; exit 2 ;; esac
case "$SID" in *[!A-Za-z0-9._-]*) echo "the session id may hold only letters, digits, '.', '_' and '-'" >&2; exit 2 ;; esac
# Look at the holder and take the seat under ONE lock, so two arms at the same moment cannot both win.
wr_lock "$REG" || { echo "could not lock the seat registry" >&2; exit 1; }
if [ "$SEAT" != NONE ]; then
  for holder in $(awk -F'\t' -v s="$SID" -v seat="$SEAT" '$2==seat && $1!=s {print $3}' "$REG"); do
    if kill -0 "$holder" 2>/dev/null; then
      wr_unlock "$REG"
      echo "REFUSED: seat $SEAT is held by another live session (waiter pid $holder). Arm as NONE, or free the seat first." >&2; exit 1
    fi
  done
fi
awk -F'\t' -v s="$SID" -v seat="$SEAT" '$1!=s && $2!=seat' "$REG" > "$REG.tmp.$$"
printf '%s\t%s\t%s\t%s\n' "$SID" "$SEAT" "$$" "$(wr_now)" >> "$REG.tmp.$$"; mv "$REG.tmp.$$" "$REG"; wr_unlock "$REG"
[ "$SEAT" = NONE ] && { echo "this session opted out of board triggers"; exit 0; }
CUR="$W/.cursor-$SEAT"; LAST="$W/.lastwake-$SEAT"
gen=$(wr_generation "$BOARD_FILE"); base=$(wc -l < "$BOARD_FILE" | tr -d ' ')
c=$(wr_cursor_get "$CUR" "$BOARD_FILE" "$AGE"); [ "$c" = none ] || base=$c
wr_cursor_put "$CUR" "$gen" "$base"           # a re-arm after a crash resumes here, not at the end
echo "armed $SEAT pid $$ at line $base $(date +%H:%M:%S)" >&2
# the posts that wake this seat: stamped first line, literal "@SEAT ACTION:" or "@ALL ACTION:", author not the seat
filter() {
  awk -v seat="$SEAT" '
    match($0, /^\[[0-9][0-9]:[0-9][0-9] · [^]]+\] /) {
      head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      author = head; sub(/^\[[0-9][0-9]:[0-9][0-9] · /, "", author); sub(/\] $/, "", author)
      if (author != seat && (index(rest, "@" seat " ACTION:") == 1 || index(rest, "@ALL ACTION:") == 1)) print
    }'
}
pend=""
while :; do
  sleep "$POLL"
  if ! grep -q "${TAB}${SEAT}${TAB}$$${TAB}" "$REG" 2>/dev/null; then
    echo "[WAITER REPLACED] a newer waiter holds seat $SEAT; this one stops (exit 3). It is not a wake." >&2; exit 3
  fi
  "$HERE/pids.sh" check >/dev/null 2>&1 || true
  g2=$(wr_generation "$BOARD_FILE"); n=$(wc -l < "$BOARD_FILE" | tr -d ' ')
  if [ "$g2" != "$gen" ] || [ "$n" -lt "$base" ]; then base=0; gen=$g2; fi    # board replaced or truncated: read it from the start
  if [ "$n" -gt "$base" ]; then
    new=$(sed -n "$((base+1)),${n}p" "$BOARD_FILE" | filter)
    base=$n
    [ -n "$new" ] && pend="${pend:+$pend
}$new"
  fi
  if [ -n "$pend" ]; then
    # loop guard: held, not lost. The held lines are delivered once the gap has passed.
    if [ -e "$LAST" ] && [ $(( $(date +%s) - $(wr_mtime "$LAST") )) -lt "$GAP" ]; then continue; fi
    wr_cursor_put "$CUR" "$gen" "$base"; : > "$LAST"
    echo "[WAKE -> $SEAT] a board line is addressed to you. Act on it, then re-arm: bash $HERE/waiter.sh $SEAT $SID (as a background job)."
    printf '%s\n' "$pend"
    exit 0
  fi
done
