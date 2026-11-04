# bin/_common.sh — sourced by every script in bin/ and hooks/. Not run on its own.
# Finds warroom.env, then sets SEATS, WARROOM_DIR, BOARD (full path in $BOARD_FILE) and a few helpers.
export LC_ALL=C
WR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WR_ENV_FILE=""
for _f in "${WARROOM_ENV:-}" "$PWD/warroom.env" "$HOME/.warroom/warroom.env" "$WR_ROOT/warroom.env"; do
  if [ -n "$_f" ] && [ -f "$_f" ]; then . "$_f"; WR_ENV_FILE="$_f"; break; fi
done
SEATS=${SEATS:-"BOSS MANAGER W1 W2"}
WARROOM_DIR=${WARROOM_DIR:-$HOME/warroom-run}
BOARD=${BOARD:-board.md}
case "$BOARD" in /*) BOARD_FILE="$BOARD" ;; *) BOARD_FILE="$WARROOM_DIR/$BOARD" ;; esac
W="$WARROOM_DIR"
mkdir -p "$W" 2>/dev/null; [ -e "$BOARD_FILE" ] || : > "$BOARD_FILE"
BOSS_SEAT=${SEATS%% *}

wr_now()   { date +%H:%M; }
wr_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
wr_seat_ok() { case " $SEATS " in *" $1 "*) return 0 ;; esac; return 1; }
# one writer at a time: mkdir is atomic; a lock older than 10 s is stale and is taken over
wr_lock() {
  _k="$1.lock"
  for _i in $(seq 1 100); do
    mkdir "$_k" 2>/dev/null && return 0
    [ $(( $(date +%s) - $(wr_mtime "$_k") )) -gt 10 ] && rmdir "$_k" 2>/dev/null
    sleep 0.1
  done
  return 1
}
wr_unlock() { rmdir "$1.lock" 2>/dev/null; }
# append one already-formatted block to the board under the lock
wr_append() {
  wr_lock "$BOARD_FILE" || { echo "could not lock the board" >&2; return 1; }
  printf '%s\n' "$1" >> "$BOARD_FILE"
  wr_unlock "$BOARD_FILE"
}
