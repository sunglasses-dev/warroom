#!/usr/bin/env bash
# waiter.sh SEAT SESSION_ID — the mention waiter. Run it as a background job from the seat's own session.
# It sleeps (no model calls, no tokens) and exits the moment a NEW board post is addressed to the seat. A post wakes a seat
# only when its FIRST line, right after the "[HH:MM · AUTHOR]" stamp, starts with "@SEAT ACTION:" or "@ALL ACTION:" and
# the author is not the seat itself. Prose, "ACTIONABLE", a quoted directive and any later line of a post wake nobody.
# A successful wake exits 0 after writing the lines and saving its position; whether and when the session is told is up to the host. Re-arm after every successful wake.
# SEAT=NONE opts a session out. One live session per seat: arming a taken seat is refused (exit 1). SESSION_ID is required.
# "Live" means the registered waiter process itself (pid and start time), so a reused pid never holds a seat.
# A waiter replaced by a newer arm of the same seat stops with exit 3, so that is never mistaken for a wake (exit 0).
# Position: the last wake is saved in $WARROOM_DIR/.cursor-SEAT with the board's inode, its first line and the last line
# read. A re-arm within WARROOM_CURSOR_MAX_AGE seconds (86400) resumes there, also across midnight; a replaced board, a
# shorter one, or one whose line at that position changed (emptied in place and refilled) is read again from its start.
# The FIRST arm, or one after that age, starts at the end of the board and sees only what follows.
# Rotate a board by moving it away (a new file starts); see bin/_cursor.sh for what is and is not noticed.
# Tuning (warroom.env): WARROOM_POLL seconds between checks (5), WARROOM_MIN_GAP seconds between two wakes (60).
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
. "$HERE/_common.sh" || exit 1
. "$HERE/_cursor.sh" || exit 1
case "${1:-}" in -h|--help|help|"") sed -n -- '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
SEAT=$1; SID=${2:-}; POLL=${WARROOM_POLL:-5}; GAP=${WARROOM_MIN_GAP:-60}; AGE=${WARROOM_CURSOR_MAX_AGE:-86400}
REG="$W/seats.tsv"; TAB="$(printf '\t')"
[ "$SEAT" = NONE ] || wr_seat_arg "$SEAT" ", or NONE"        # before the registry is created or any per-seat path is built
case "$SID" in ''|unknown) echo "a session id is required: waiter.sh SEAT SESSION_ID (see README, quick start)" >&2; exit 2 ;; esac
case "$SID" in *[!A-Za-z0-9._-]*) echo "the session id may hold only letters, digits, '.', '_' and '-'" >&2; exit 2 ;; esac
wr_create "$REG" || { echo "cannot create the seat registry $REG" >&2; exit 1; }
CUR="$W/.cursor-$SEAT"; LAST="$W/.lastwake-$SEAT"
QW=$(printf '%q' "$HERE/waiter.sh") || { echo "cannot quote the path of the waiter" >&2; exit 1; }   # for the re-arm hint in the wake header
# No row without an identity: the waiter's own start time must be readable before it takes anything. Without it a row could
# only be judged by its pid, and a reused pid would then look like a live waiter.
START=$(wr_started $$) || { echo "cannot read the start time of this waiter (pid $$; ps failed), so its seat row could not be told from a reused pid: not armed. Try again." >&2; exit 1; }
# Arming (take the seat, read the saved position) and delivering a wake both run under the seat's cursor lock, so a
# waiter that is being replaced can never deliver after its replacement has taken over: exactly one of them delivers.
# Lock order is always the cursor lock, then the registry lock.
if [ "$SEAT" != NONE ]; then wr_lock "$CUR" || { echo "could not lock the cursor of seat $SEAT" >&2; exit 1; }; fi
# Look at the holder and take the seat under ONE lock, so two arms at the same moment cannot both win.
wr_lock "$REG" || { wr_unlock "$CUR"; echo "could not lock the seat registry" >&2; exit 1; }
# Every state write is checked: when one fails the waiter says so and exits 1 without arming, and the file it was writing
# is as it was (a temp made by this arm, then a rename; only that temp is removed, and one that cannot be removed is reported).
reg_t=""
# judge_holder PID START COLS: the registry row of another session on this seat. A live waiter or an unknown one refuses the
# arm (exit 1, nothing changed); a dead one is no holder. "-" stands for an empty start time: read would merge the two tabs.
judge_holder() {
  _jh_s=$2; [ "$_jh_s" = - ] && _jh_s=""
  _jh_r=$(wr_rowproc "$1" "$_jh_s" "$3") || { wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not judge the holder of seat $SEAT: not armed" >&2; exit 1; }
  case "$_jh_r" in
    alive) wr_unlock "$REG"; wr_unlock "$CUR"
      echo "REFUSED: seat $SEAT is held by another live session (waiter pid $1). Arm as NONE, or free the seat first." >&2; exit 1 ;;
    unknown) wr_unlock "$REG"; wr_unlock "$CUR"
      echo "REFUSED: seat $SEAT is held by pid $1, whose start time is not recorded or cannot be read (ps failed), so it cannot be told from a reused pid. Nothing changed; try again, or free the seat." >&2; exit 1 ;;
  esac
  return 0
}
if [ "$SEAT" != NONE ]; then
  # a holder is the waiter process the row names: same pid AND same start time (column 5), so a stale row whose pid now
  # belongs to an unrelated process does not block the seat. A row with an empty start time (not written by this version)
  # is unknown while its pid lives; only a four-column row from an older version is judged by the pid alone.
  # the registry is read once, checked, and then walked from that copy: a registry that cannot be read is not "no holder"
  regrows=$(wr_registry_read "$REG") || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not read the seat registry $REG: not armed" >&2; exit 1; }
  holders=$( set -o pipefail; printf '%s\n' "$regrows" | awk -F'\t' -v s="$SID" -v seat="$SEAT" 'BEGIN{OFS="\t"} $2==seat && $1!=s {print $3, ($5==""?"-":$5), NF}' ) || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not look up seat $SEAT in the seat registry $REG: not armed" >&2; exit 1; }
  if [ -n "$holders" ]; then
    while IFS="$TAB" read -r holder hstart hcols; do judge_holder "$holder" "$hstart" "$hcols"; done <<< "$holders"
  fi
  # the position first: it only repeats what the next arm would compute, so a failed registry write after it changes nothing
  gen=$(wr_generation "$BOARD_FILE") || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not read the board $BOARD_FILE: not armed" >&2; exit 1; }
  base=$(wr_lines "$BOARD_FILE") || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not count the lines of the board $BOARD_FILE: not armed" >&2; exit 1; }
  c=$(wr_cursor_get "$CUR" "$BOARD_FILE" "$AGE") || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not read the saved position of seat $SEAT ($CUR), or checksum the board $BOARD_FILE: not armed. A damaged position file named above can be removed to start again at the end of the board." >&2; exit 1; }
  [ "$c" = none ] || base=$c
  lastck=$(wr_prefixsum "$BOARD_FILE" "$base") || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not checksum the board $BOARD_FILE: not armed" >&2; exit 1; }
  wr_cursor_put "$CUR" "$gen" "$base" "$lastck" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not save the position of seat $SEAT ($CUR): not armed. Is $W writable and not full?" >&2; exit 1; }
fi
wr_temp "$REG" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not create a temporary file next to the seat registry: not armed" >&2; exit 1; }
reg_t=$_WR_TMP
if [ "$SEAT" != NONE ]; then
  # a real seat replaces this session's old row and any other row of the seat
  awk -F'\t' -v s="$SID" -v seat="$SEAT" '$1!=s && $2!=seat' "$REG" > "$reg_t" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not write the seat registry: not armed" >&2; exit 1; }
else
  # NONE is a shared marker, not a seat: replace only this session's own row, never another session's opt-out
  awk -F'\t' -v s="$SID" '$1!=s' "$REG" > "$reg_t" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not write the seat registry: not armed" >&2; exit 1; }
fi
# row: session, seat, waiter pid, armed at, waiter start time (never empty: see START above)
_at=$(wr_now) || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not read the clock: not armed" >&2; exit 1; }
wr_hhmm "$_at" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not read the clock: not armed" >&2; exit 1; }
printf '%s\t%s\t%s\t%s\t%s\n' "$SID" "$SEAT" "$$" "$_at" "$START" >> "$reg_t" && wr_replace "$reg_t" "$REG" || { wr_drop "$reg_t"; wr_unlock "$REG"; wr_unlock "$CUR"; echo "could not update the seat registry $REG: not armed" >&2; exit 1; }
wr_unlock "$REG"
[ "$SEAT" = NONE ] && { echo "this session opted out of board triggers"; exit 0; }
wr_unlock "$CUR"
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
# gap_state: prints 1 while the last delivery is less than GAP seconds old (hold the lines), 0 when the gap is open, and "ahead" when
# the marker is dated ahead of the clock (a clock stepped back): that is an open gap, said once by gap_open. Status 1 and nothing
# printed when the clock or the marker cannot be read. A caller that cannot tell delivers nothing and looks again.
gap_state() {
  _ga=$(wr_absent "$LAST") || return 1
  if [ "$_ga" = yes ]; then echo 0; return 0; fi
  _gn=$(wr_epoch) || return 1
  _gm=$(wr_mtime "$LAST") || return 1
  [ "$_gm" -le "$_gn" ] || { echo ahead; return 0; }
  if [ $(( _gn - _gm )) -lt "$GAP" ]; then echo 1; else echo 0; fi
}
# gap_open STATE: status 0 when the gap is open (0, or "ahead": a marker dated ahead of the clock is no reason to hold a seat, and
# the delivery that follows re-stamps it to now), 1 when the lines are held. The ahead case is said once per waiter run: deliver
# checks the gap twice per attempt and a lock miss repeats the attempt at the next poll. Called in the main shell, never in $( ).
gap_said=""
gap_open() {
  case "$1" in
    0) return 0 ;;
    ahead) [ -n "$gap_said" ] || { echo "[WAITER] the gap marker $LAST is dated ahead of the clock: treating the gap as open and delivering; the delivery re-stamps the marker to now" >&2; gap_said=1; }; return 0 ;;
    *) return 1 ;;
  esac
}
replaced() { echo "[WAITER REPLACED] a newer waiter holds seat $SEAT; this one stops (exit 3). It is not a wake." >&2; exit 3; }
# mine: is this still the seat's waiter? Status 0 yes. The registry was read and holds no such row (an absent registry is an
# empty one): the waiter was replaced and stops with exit 3. Status 1: the registry could not be read, so it cannot tell; the
# caller keeps its place and looks again.
mine() {
  _mr=$( set -o pipefail; wr_registry_read "$REG" | awk -F'\t' -v s="$SEAT" -v p="$$" '$2 == s && $3 == p && NF >= 4 { f = 1 } END { print f + 0 }' ) || return 1
  case "$_mr" in 1) return 0 ;; 0) replaced ;; *) return 1 ;; esac
}
# the two scratch files of one poll are temps this waiter made (snap_t, chunk_t): removed after each poll and at exit; a temp
# that cannot be removed is reported with its path
snap_t=""; chunk_t=""; trap 'wr_drop "$chunk_t"; wr_drop "$snap_t"' EXIT
pend=""
trap '' PIPE      # a closed reader gives a failed write (checked below), not a silent death by SIGPIPE
# observe: one look at the registry and the board. It moves the checkpoint (lastck, base) and collects the wake lines in pend only
# after the snapshot, the sum and the filter all succeeded. Status 1 means nothing was consumed and the reason was said; the loop
# looks again at the next poll.
observe() {
  mine || { echo "[WAITER] the seat registry $REG could not be read; staying up, will look again" >&2; return 1; }
  bash "$HERE/pids.sh" check >/dev/null || true      # stdout dropped, stderr kept: a ledger lock or read failure is shown
  g2=$(wr_generation "$BOARD_FILE") || { echo "[WAITER] could not read the board $BOARD_FILE; nothing consumed, will look again" >&2; return 1; }
  n=$(wr_lines "$BOARD_FILE") || { echo "[WAITER] could not count the lines of the board $BOARD_FILE; nothing consumed, will look again" >&2; return 1; }
  # board replaced, shorter, or changed anywhere in the part already read: read it from the start. A sum that cannot be
  # computed consumes nothing: the checkpoint stays and the next poll tries again.
  pk=""
  if [ "$base" -gt 0 ]; then pk=$(wr_prefixsum "$BOARD_FILE" "$base") || { echo "[WAITER] could not checksum the board in $W; nothing consumed, will look again" >&2; return 1; }; fi
  if [ "$g2" != "$gen" ] || [ "$n" -lt "$base" ] || { [ "$base" -gt 0 ] && [ "$pk" != "$lastck" ]; }; then base=0; gen=$g2; fi
  if [ "$n" -gt "$base" ]; then
    # one read: the new lines and the sum of everything read come from the same bytes
    snap_t=""; chunk_t=""
    wr_temp "$CUR" || { echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    snap_t=$_WR_TMP
    wr_temp "$CUR" || { wr_drop "$snap_t"; echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    chunk_t=$_WR_TMP
    head -n "$n" "$BOARD_FILE" > "$snap_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    lastck_new=$(wr_sumstdin < "$snap_t") || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    tail -n "$((n-base))" "$snap_t" > "$chunk_t" || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    new=$(filter < "$chunk_t") || { wr_drop "$chunk_t"; wr_drop "$snap_t"; echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; return 1; }
    wr_drop "$chunk_t"; wr_drop "$snap_t"; snap_t=""; chunk_t=""
    lastck=$lastck_new
    base=$n
    [ -n "$new" ] && pend="${pend:+$pend
}$new"
  fi
  return 0
}
# deliver: with lines held in pend, wake the seat. Status 1: held (the gap since the last wake is not over) or not deliverable
# now; the lines stay in pend and the next poll tries again. It leaves the waiter only by exit: 0 after output and checkpoint,
# 3 when replaced, 1 when a delivery step failed.
deliver() {
  # loop guard: held, not lost. The held lines are delivered once the gap has passed.
  gapheld=$(gap_state) || { echo "[WAITER] could not read the clock; nothing delivered, will look again" >&2; return 1; }
  gap_open "$gapheld" || return 1
  # Deliver under the cursor lock: recheck ownership and gap, then print header and lines before saving marker and position.
  wr_lock "$CUR" || return 1
  mine || { wr_unlock "$CUR"; echo "[WAITER] the seat registry $REG could not be read; nothing delivered, will look again" >&2; return 1; }
  gapheld=$(gap_state) || { wr_unlock "$CUR"; echo "[WAITER] could not read the clock; nothing delivered, will look again" >&2; return 1; }
  gap_open "$gapheld" || { wr_unlock "$CUR"; return 1; }
  # The wake is printed first and marked after it, each step checked alone: header, lines, gap marker, position.
  # A failed delivery step exits 1 without attempting later delivery steps. Header or payload failure leaves the delivery
  # checkpoint unchanged; stamp failure may leave a newly created marker, and position-save failure retains the fresh marker and
  # old cursor. After repaired I/O, retry can repeat lines only while the retained position is readable, usable and within its age
  # limit and the board remains available.
  # Nothing is unlinked to undo a failure. touch, never ": >": LAST only carries a
  # time, and a BOARD configured with the same name must not be emptied. Exit 0 happens only here: output written AND
  # checkpoint saved (not host acknowledgement). trap '' PIPE (set before the loop) turns a closed reader into a failed write.
  if ! echo "[WAKE -> $SEAT] a board line is addressed to you. Act on it, then re-arm: bash $QW $SEAT $SID (as a background job)."; then
    wr_unlock "$CUR"; echo "[WAITER ERROR] could not write the wake header to the output; no delivery checkpoint was saved. After fixing I/O, re-arm promptly; retained lines can repeat if the board and saved position remain readable, usable and within the age limit (see docs/PROTOCOL.md)." >&2; exit 1
  fi
  if ! printf '%s\n' "$pend"; then
    wr_unlock "$CUR"; echo "[WAITER ERROR] could not write the lines to the output; no delivery checkpoint was saved. After fixing I/O, re-arm promptly; retained lines can repeat if the board and saved position remain readable, usable and within the age limit (see docs/PROTOCOL.md). The header and a part of the lines may repeat." >&2; exit 1
  fi
  if ! wr_stamp "$LAST"; then
    wr_unlock "$CUR"; echo "[WAITER ERROR] the lines were printed but not marked: could not update the gap marker in $W (full or read-only?). The position was NOT saved. After fixing I/O, re-arm promptly; retained lines can repeat if the board and saved position remain readable, usable and within the age limit (see docs/PROTOCOL.md)." >&2; exit 1
  fi
  if ! wr_cursor_put "$CUR" "$gen" "$base" "$lastck"; then
    wr_unlock "$CUR"; echo "[WAITER ERROR] the lines were printed but not marked: could not save the position of seat $SEAT in $W (full or read-only?). The old position stays and the gap marker stays. After fixing I/O, re-arm promptly; retained lines can repeat if the board and saved position remain readable, usable and within the age limit (see docs/PROTOCOL.md)." >&2; exit 1
  fi
  wr_unlock "$CUR"
  exit 0
}
while :; do
  sleep "$POLL"
  observe || continue
  [ -n "$pend" ] || continue
  deliver || continue
done
