# shellcheck shell=bash
# bin/_common.sh — sourced by every script in bin/ and hooks/. Not run on its own.
# Finds warroom.env, then sets SEATS, WARROOM_DIR, BOARD (full path in $BOARD_FILE) and a few helpers.
export LC_ALL=C
WR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # WR_ENV_FILE and BOSS_SEAT are read by the scripts that source this file
WR_ENV_FILE=""
for _f in "${WARROOM_ENV:-}" "$PWD/warroom.env" "$HOME/.warroom/warroom.env" "$WR_ROOT/warroom.env"; do
  # shellcheck source=/dev/null disable=SC2034
  if [ -n "$_f" ] && [ -f "$_f" ]; then . "$_f"; WR_ENV_FILE="$_f"; break; fi
done
SEATS=${SEATS:-"BOSS MANAGER W1 W2"}
WARROOM_DIR=${WARROOM_DIR:-$HOME/warroom-run}
BOARD=${BOARD:-board.md}
case "$BOARD" in /*) BOARD_FILE="$BOARD" ;; *) BOARD_FILE="$WARROOM_DIR/$BOARD" ;; esac
W="$WARROOM_DIR"
mkdir -p "$W" 2>/dev/null; [ -e "$BOARD_FILE" ] || : > "$BOARD_FILE"
# shellcheck disable=SC2034
BOSS_SEAT=${SEATS%% *}

wr_now()   { date +%H:%M; }
# GNU stat first: on Linux `stat -f` means "file system status" and prints several lines, so it must not run first.
# On macOS/BSD `stat -c` fails without printing anything, and the BSD form runs instead.
wr_mtime() {
  _m=$(stat -c %Y "$1" 2>/dev/null) || _m=$(stat -f %m "$1" 2>/dev/null) || _m=0
  case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
  echo "$_m"
}
wr_seat_ok() { case " $SEATS " in *" $1 "*) return 0 ;; esac; return 1; }
# One writer at a time. mkdir is atomic, and the holder writes its pid into the lock. A lock is taken over only when
# that pid is gone (or, if the holder died before writing its pid, when the lock is over 10 s old); a live holder is
# waited for and never evicted, and only the holder can release it. Limits: one machine, a local file system, and a pid
# that has been reused by another process looks alive.
wr_reclaim() { # $1 lock directory, $2 the dead owner we saw ("" = no owner written)
  _d="$1.dead.$$"
  mv "$1" "$_d" 2>/dev/null || return 0                 # someone else reclaimed it first
  if [ "$(cat "$_d/owner" 2>/dev/null)" = "$2" ]; then rm -f "$_d/owner"; rmdir "$_d" 2>/dev/null
  else mv "$_d" "$1" 2>/dev/null; fi                     # it was a new, live lock: put it back
}
wr_lock() {
  _k="$1.lock"
  for _i in $(seq 1 100); do
    if mkdir "$_k" 2>/dev/null; then printf '%s\n' "$$" > "$_k/owner"; return 0; fi
    _o=$(cat "$_k/owner" 2>/dev/null)
    if [ -n "$_o" ]; then
      kill -0 "$_o" 2>/dev/null || wr_reclaim "$_k" "$_o"
    elif [ $(( $(date +%s) - $(wr_mtime "$_k") )) -gt 10 ]; then
      wr_reclaim "$_k" ""
    fi
    sleep 0.1
  done
  return 1
}
wr_unlock() {
  _k="$1.lock"
  [ "$(cat "$_k/owner" 2>/dev/null)" = "$$" ] || return 0   # not ours: leave it alone
  rm -f "$_k/owner"; rmdir "$_k" 2>/dev/null; return 0
}
# append one already-formatted block to the board under the lock; fails (and says so) when the board cannot be written
wr_append() {
  wr_lock "$BOARD_FILE" || { echo "could not lock the board" >&2; return 1; }
  _rc=0; printf '%s\n' "$1" >> "$BOARD_FILE" || _rc=1
  wr_unlock "$BOARD_FILE"
  [ "$_rc" = 0 ] || echo "could not append to $BOARD_FILE" >&2
  return "$_rc"
}
