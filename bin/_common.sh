# shellcheck shell=bash
# bin/_common.sh — sourced by every script in bin/ and hooks/. Not run on its own.
# Reads warroom.env as data (bin/_config.sh: one file, a strict KEY=VALUE grammar, never sourced), then sets SEATS,
# WARROOM_DIR, BOARD (full path in $BOARD_FILE) and a few helpers. A bad config stops the script with the reason.
export LC_ALL=C
WR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/_config.sh
. "$WR_ROOT/bin/_config.sh"
# shellcheck disable=SC2034  # WR_ENV_FILE and BOSS_SEAT are read by the scripts that source this file
WR_ENV_FILE=$(wr_config_path)
# Exit code for a bad config: 2 in bin/ scripts. Hooks set WR_CONFIG_EXIT=1 before sourcing this file, because Claude
# Code reads a hook's exit 2 as "block this prompt": one bad line in warroom.env would lock every session out.
# Exit 1 is shown as a hook error and the prompt goes through. Only 1 and 2 are accepted.
case "${WR_CONFIG_EXIT:-}" in 1) ;; *) WR_CONFIG_EXIT=2 ;; esac
if [ -f "$WR_ENV_FILE" ]; then wr_load_config "$WR_ENV_FILE" || exit "$WR_CONFIG_EXIT"; else WR_ENV_FILE=""; fi
SEATS=${SEATS:-"BOSS MANAGER W1 W2"}
wr_seats_ok "$SEATS" || { echo "SEATS='$SEATS': names are [A-Z][A-Z0-9_]{0,15}, no repeats; ALL, NONE and GUARD are reserved" >&2; exit "$WR_CONFIG_EXIT"; }
WARROOM_DIR=${WARROOM_DIR:-$HOME/warroom-run}
BOARD=${BOARD:-board.md}
case "$BOARD" in /*) BOARD_FILE="$BOARD" ;; *) BOARD_FILE="$WARROOM_DIR/$BOARD" ;; esac
W="$WARROOM_DIR"
# Create a missing board with >>, which never truncates: two scripts that both find it missing must not erase each
# other's first post. If the run directory or the board cannot be created, say so and stop (a hook exits 1, not 2).
mkdir -p "$W" 2>/dev/null
if [ ! -e "$BOARD_FILE" ]; then
  mkdir -p "$(dirname "$BOARD_FILE")" 2>/dev/null
  : >> "$BOARD_FILE" 2>/dev/null || { echo "cannot create the board $BOARD_FILE" >&2; exit "$WR_CONFIG_EXIT"; }
fi
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
# --- The writer lock (design: docs/design/LOCK_AND_MERGE_GATE.md, Part A) -------------------------------------------
# One writer at a time per protected file, for writers that use these functions (the lock is advisory).
#   wr_lock FILE      take FILE's lock, waiting up to WARROOM_LOCK_WAIT seconds (default 10). 0 = held, 1 = not taken
#                     (the reason is on stderr), 2 = refused (subshell, alias, already held, nesting limit)
#   wr_unlock FILE    release FILE's lock if this shell holds it; otherwise do nothing
#   wr_run CMD ARGS   run CMD with the lock descriptors closed: use it for every script started inside a section
# How it works: FILE's lock is flock(2) on the sidecar FILE.flock, opened on fd 8 or 9 of this shell and locked by a
# short python3 helper. The sidecar is never removed or renamed (removing it would let the next writer lock a new file),
# and nothing ever unlocks it with LOCK_UN. The lock is released when the last copy of the descriptor closes: at
# wr_unlock, or when the holder exits or is killed. Children inherit a copy, so scripts started inside a section go
# through wr_run; short foreground commands (mv, sed, awk, cat, date) keep a copy only while the holder waits for them.
# Residual: if such a command, or the helper itself, is stopped (SIGSTOP, a hung disk) and the holder is killed, the
# lock stays held until that command ends. Waiters time out with a message; nothing steals the lock.
# Rules: fds 8 and 9 are reserved for this lock. Two locks at most per shell, never the same FILE twice. Never from a
# ( ... ), $( ... ) or pipeline subshell: the top level of a script or its functions only. One name per protected file:
# a FILE that is a symlink, a FILE with hard links, or a sidecar that is a symlink is refused; symlinked parent folders
# are fine (the key is the physical folder plus the file name), and an absolute BOARD path gets the same checks.
# Limits: one machine and a local file system (flock over NFS/SMB is not trusted); cooperating writers only (an editor
# or an "echo >>" that bypasses board.sh is not locked); re-pointing a parent symlink or moving the run folder while
# writers run is not supported. Upgrading from the old mkdir lock: stop every session, waiter and job that uses this
# run folder first; a leftover FILE.lock folder is then inert. Never delete a .flock file.
# Lock order (outer, then inner), the only nestings: job ledger -> board (pids.sh check posts a dead job), guard mark
# -> board (board-guard.sh posts an idle seat), seat cursor -> seat registry (waiter.sh arming). Nothing takes them in
# the other order. A caller that cannot lock prints its own line and gives up, except the waiter's delivery, which
# tries again on its next poll. Why python3 and not flock(1): flock(1) ships with Linux but not with macOS, and the
# helper must behave the same on both.
_WR_SLOT8=""; _WR_SLOT9=""
_wr_path() { # FILE -> _WR_KEY = physical parent folder + base name (no checks)
  _wr_d=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  _WR_KEY="$_wr_d/$(basename "$1")"
}
_wr_links() { # FILE -> its link count, "" if unreadable (GNU stat first, see wr_mtime)
  _wr_n=$(stat -c %h "$1" 2>/dev/null) || _wr_n=$(stat -f %l "$1" 2>/dev/null) || _wr_n=""
  case "$_wr_n" in ''|*[!0-9]*) echo "" ;; *) echo "$_wr_n" ;; esac
}
_wr_sub_ok() { # every lock function refuses inside a subshell, before it touches anything
  [ "${BASH_SUBSHELL:-0}" = 0 ] && return 0
  echo "lock used from a subshell ($1 $2): lock and unlock at the top level of a script or in its functions" >&2; return 2
}
wr_lock() {
  _wr_sub_ok wr_lock "$1" || return 2
  _wr_path "$1" || { echo "could not open lock file for $1: its folder cannot be resolved" >&2; return 1; }
  _wr_k=$_WR_KEY
  if [ -L "$_wr_k" ]; then echo "$1 is a symlink; point the war room at the real path (a protected file has one name)" >&2; return 2; fi
  if [ -e "$_wr_k" ]; then
    _wr_c=$(_wr_links "$_wr_k")
    [ -n "$_wr_c" ] || { echo "could not open lock file for $1: its link count cannot be read" >&2; return 1; }
    [ "$_wr_c" -le 1 ] || { echo "$1 has $_wr_c hard links; a protected file must have exactly one name" >&2; return 2; }
  fi
  if [ -L "$_wr_k.flock" ]; then echo "lock file $_wr_k.flock is a symlink; refusing to lock through it" >&2; return 2; fi
  if [ "$_WR_SLOT8" = "$_wr_k" ] || [ "$_WR_SLOT9" = "$_wr_k" ]; then echo "already holding the lock for $1" >&2; return 2; fi
  if [ -z "$_WR_SLOT8" ]; then _wr_fd=8; elif [ -z "$_WR_SLOT9" ]; then _wr_fd=9; else echo "lock nesting limit (2) reached at $1" >&2; return 2; fi
  # open the sidecar with >> (created if missing, never truncated); the group keeps bash's own error line off stderr
  if [ "$_wr_fd" = 8 ]; then { exec 8>>"$_wr_k.flock"; } 2>/dev/null; else { exec 9>>"$_wr_k.flock"; } 2>/dev/null; fi || {
    echo "could not open lock file $_wr_k.flock: $( { : >> "$_wr_k.flock"; } 2>&1 | sed 's/.*: //' | head -1)" >&2; return 1; }
  _wr_w=${WARROOM_LOCK_WAIT:-10}; case "$_wr_w" in ''|*[!0-9.]*) _wr_w=10 ;; esac
  _wr_e=$(python3 -I -S -c '
import errno, fcntl, sys, time
fd, wait = int(sys.argv[1]), float(sys.argv[2])
end = time.monotonic() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); sys.exit(0)
    except OSError as e:
        if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            sys.stderr.write("%s\n" % (e.strerror or e)); sys.exit(3)
    if time.monotonic() >= end: sys.exit(1)
    time.sleep(0.02)' "$_wr_fd" "$_wr_w" 2>&1 >/dev/null)   # the helper only inherits fd 8/9; its stderr is kept
  _wr_rc=$?
  if [ "$_wr_rc" = 0 ]; then
    if [ "$_wr_fd" = 8 ]; then _WR_SLOT8=$_wr_k; else _WR_SLOT9=$_wr_k; fi
    return 0
  fi
  if [ "$_wr_fd" = 8 ]; then exec 8>&-; else exec 9>&-; fi    # failed: close only the descriptor just opened
  if [ "$_wr_rc" = 1 ]; then echo "could not lock $1: held by another writer for ${_wr_w}s" >&2
  else echo "lock helper failed for $1: ${_wr_e:-no message} (exit $_wr_rc)" >&2; fi
  return 1
}
wr_unlock() {
  _wr_sub_ok wr_unlock "$1" || return 2
  _wr_path "$1" || return 0
  if [ -n "$_WR_SLOT8" ] && [ "$_WR_SLOT8" = "$_WR_KEY" ]; then exec 8>&-; _WR_SLOT8=""
  elif [ -n "$_WR_SLOT9" ] && [ "$_WR_SLOT9" = "$_WR_KEY" ]; then exec 9>&-; _WR_SLOT9=""; fi
  return 0
}
wr_run() {
  _wr_sub_ok wr_run "$1" || return 2
  "$@" 8>&- 9>&-
}
# append one already-formatted block to the board under the lock; fails (and says so) when the board cannot be written
wr_append() {
  wr_lock "$BOARD_FILE" || { echo "could not lock the board" >&2; return 1; }
  _rc=0; printf '%s\n' "$1" >> "$BOARD_FILE" || _rc=1
  wr_unlock "$BOARD_FILE"
  [ "$_rc" = 0 ] || echo "could not append to $BOARD_FILE" >&2
  return "$_rc"
}
# Process identity = a pid plus the time its process started (ps lstart, C locale, blanks squeezed; resolution one second).
# The job ledger, the seat registry, the idle guard and the waiter hook all judge a recorded process with wr_proc.
# wr_started PID: print the start time of PID; exit 1 (nothing printed) when it cannot be read.
wr_started() {
  _wr_st=$( { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'; } 8>&- 9>&- )   # no lock copy in ps
  [ -n "$_wr_st" ] || return 1
  printf '%s\n' "$_wr_st"
}
# wr_proc PID [STARTED]: print one word.
#   dead     no such process, or (when STARTED is given) the pid now belongs to a process that started at another time
#   alive    the process exists and, when STARTED is given, started at that time; with no STARTED the pid alone decides
#   unknown  the process exists but its start time cannot be read (ps failed): it is neither alive nor dead. Callers
#            keep what they hold and say so; they never treat unknown as dead.
wr_proc() {
  case "$1" in ''|*[!0-9]*|?????????????*) echo dead; return 0 ;; esac
  [ "$((10#$1))" -gt 0 ] || { echo dead; return 0; }          # pid 0 would mean the whole process group
  kill -0 "$1" 2>/dev/null || { echo dead; return 0; }
  [ -n "${2:-}" ] || { echo alive; return 0; }
  if _wr_ps=$(wr_started "$1"); then
    if [ "$_wr_ps" = "$2" ]; then echo alive; else echo dead; fi
  elif kill -0 "$1" 2>/dev/null; then echo unknown
  else echo dead; fi                                           # it ended between the two looks
}
