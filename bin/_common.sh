# shellcheck shell=bash
# bin/_common.sh — sourced by every script in bin/ and hooks/. Not run on its own.
# Reads warroom.env as data (bin/_config.sh: one file, a strict KEY=VALUE grammar, never sourced), then sets SEATS,
# WARROOM_DIR, BOARD (full path in $BOARD_FILE) and a few helpers. A bad config stops the script with the reason.
export LC_ALL=C
WR_ROOT=$(cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd) || exit 1
# shellcheck source=bin/_config.sh
. "$WR_ROOT/bin/_config.sh" || exit 1
# Exit code for a bad config: 2 in bin/ scripts. Hooks set WR_CONFIG_EXIT=1 before sourcing this file, because Claude
# Code reads a hook's exit 2 as "block this prompt": one bad line in warroom.env would lock every session out.
# Exit 1 is shown as a hook error and the prompt goes through. Only 1 and 2 are accepted.
case "${WR_CONFIG_EXIT:-}" in 1) ;; *) WR_CONFIG_EXIT=2 ;; esac
# --- Where things go: resolve first, refuse before anything is created ---------------------------------------------
# The run folder W, the board B and the config file C are resolved once, from metadata only (a stat-like look: the contents
# of a settings file are never opened), and the run stops before the bootstrap when one of them is unusable, is named like
# a Claude Code settings file, is the config folder, or collides with a name this tool writes. Not a sandbox: see SECURITY.md.
wr_fold() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }          # ASCII only; Unicode spellings are not folded (SECURITY.md)
# python3 is a hard dependency (locks, state writes, hook input). Checked first, with a call that imports nothing, so the
# failure names python3 instead of surfacing later as a lock or parse error.
wr_need_python() {
  python3 -I -S -c 'pass' >/dev/null 2>&1 || { echo "python3 is required (locks, state writes and the hooks use it) and must be on the PATH of this process; install it or fix PATH and try again" >&2; return 2; }
}
# wr_kind PATH [follow]: what PATH is, one word: absent, file, dir, link or other. The link itself is looked at (lstat), or what it
# points to when the second word is "follow". Only "no such file" means absent: a folder that cannot be searched, a parent that is
# a file and a link loop are status 1 with nothing printed (cannot tell), never "absent".
wr_kind() {
  _wk=$(python3 -I -S -c 'import errno, os, stat, sys
look = os.stat if len(sys.argv) > 2 else os.lstat
try: m = look(sys.argv[1]).st_mode
except OSError as e:
    if e.errno == errno.ENOENT: print("absent"); sys.exit(0)
    sys.exit(3)
print("link" if stat.S_ISLNK(m) else "file" if stat.S_ISREG(m) else "dir" if stat.S_ISDIR(m) else "other")' "$@" 2>/dev/null) || return 1
  case "$_wk" in absent|file|dir|link|other) printf '%s\n' "$_wk" ;; *) return 1 ;; esac
}
# wr_same FILE OTHER...: 0 when FILE is none of the OTHERs (same device and inode, links followed), else the number of the first
# one it is. A name that does not lead to a file (no such file, a loop, a parent that is a file) is not the same as anything;
# any other stat failure is status 1 with nothing printed.
wr_same() {
  _wm=$(python3 -I -S -c 'import errno, os, sys
gone = (errno.ENOENT, errno.ELOOP, errno.ENOTDIR)
try: a = os.stat(sys.argv[1])
except OSError as e:
    if e.errno in gone: print(0); sys.exit(0)
    sys.exit(3)
for i, p in enumerate(sys.argv[2:], 1):
    try: b = os.stat(p)
    except OSError as e:
        if e.errno in gone: continue
        sys.exit(3)
    if os.path.samestat(a, b): print(i); sys.exit(0)
print(0)' "$@" 2>/dev/null) || return 1
  case "$_wm" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_wm"
}
# wr_resolve PATH KIND: KIND is dir, file or input. 0 = _WR_RES holds the physical absolute path; 1 = _WR_WHY says why not.
# Nothing is created and no file is opened. A missing tail is appended as written (lower parts that exist are resolved).
wr_resolve() {
  _WR_RES=""; _WR_WHY=""; _rp=$1; _rk=$2
  case "$_rp" in /*) ;; *) _WR_WHY="is not an absolute path"; return 1 ;; esac
  _rb=${_rp#/}
  if [ "$_rk" = dir ]; then case "$_rb" in */) _rb=${_rb%/} ;; esac; fi          # one trailing / is allowed on a folder
  [ -n "$_rb" ] || { _WR_WHY="names no folder or file (it is /)"; return 1; }
  case "/$_rb/" in *//*|*/./*|*/../*) _WR_WHY="has an empty, . or .. component, or ends in a second /"; return 1 ;; esac
  if [ "$_rk" = dir ]; then _rs="/$_rb"; _rl=""
  else _rl=${_rb##*/}; case "$_rb" in */*) _rs="/${_rb%/*}" ;; *) _rs=/ ;; esac; fi   # a file or input starts at its parent
  _rm=""
  _WR_WHY="cannot be resolved: its nearest existing parent is not a searchable folder"
  while :; do
    _rv=$(wr_kind "$_rs") || return 1
    [ "$_rv" = absent ] || break
    _rm="/${_rs##*/}$_rm"; _rs=${_rs%/*}; [ -n "$_rs" ] || _rs=/
  done
  _ra=$(cd -P -- "$_rs" 2>/dev/null && pwd -P) || return 1
  _WR_WHY=""
  [ "$_ra" = / ] && _ra=""
  case "$_rk" in
    dir) _WR_RES="$_ra$_rm" ;;
    file)
      _WR_RES=""; _WR_WHY="cannot be examined"
      _rv=$(wr_kind "$_ra$_rm/$_rl") || return 1
      _WR_RES="$_ra$_rm/$_rl"; _WR_WHY=""
      case "$_rv" in
        absent|file) ;;
        link) _WR_WHY="is a symlink; a protected file has one name"; _WR_RES=""; return 1 ;;
        *) _WR_WHY="exists and is not a regular file"; _WR_RES=""; return 1 ;;
      esac ;;
    input)   # the config file may be a symlink (dotfile managers): its identity follows the links; a loop is refused
      _WR_RES=$(python3 -I -S -c 'import errno, os, sys
try: os.stat(sys.argv[1])
except OSError as e:
    if e.errno == errno.ELOOP: sys.exit(4)
print(os.path.realpath(sys.argv[1]))' "$_rp" 2>/dev/null); _rr=$?
      if [ "$_rr" = 4 ]; then _WR_RES=""; _WR_WHY="config path loops"; return 1; fi
      if [ "$_rr" != 0 ] || [ -z "$_WR_RES" ]; then _WR_RES=""; _WR_WHY="cannot be resolved"; return 1; fi ;;
    *) _WR_WHY="unknown kind"; return 1 ;;
  esac
  return 0
}
# The names this tool writes inside a run folder, by family (folded names): a board or config file may not take one.
wr_reserved_name() {
  case "$1" in
    seats.tsv|pids.tsv|.cursor-*|.lastwake-*|.anchor-*|.guard-*|.poll-*|.snap-*|.wrtmp.*|*.flock|*.tmp.[0-9]*|*.chunk.[0-9]*) return 0 ;;
  esac
  return 1
}
# wr_reserved_below ROOT PATH (both folded): 0 when PATH is below ROOT and a component of the part below ROOT is reserved
wr_reserved_below() {
  case "$2" in "$1"/*) ;; *) return 1 ;; esac
  _rbr=${2#"$1"/}
  while [ -n "$_rbr" ]; do
    wr_reserved_name "${_rbr%%/*}" && return 0
    case "$_rbr" in */*) _rbr=${_rbr#*/} ;; *) _rbr="" ;; esac
  done
  return 1
}
# wr_ef_reserved FILE: prints yes when FILE is the same file (hard link or link target) as an existing top-level reserved entry of
# W, else no; status 1 and nothing printed when that cannot be told.
wr_ef_reserved() {
  _er_f=$1; set --
  for _er in "$WR_W_RES"/* "$WR_W_RES"/.[!.]* "$WR_W_RES"/..?*; do
    _ern=$(wr_fold "${_er##*/}") || return 1
    if wr_reserved_name "$_ern"; then set -- "$@" "$_er"; fi
  done
  [ "$#" -gt 0 ] || { echo no; return 0; }
  _erv=$(wr_same "$_er_f" "$@") || return 1
  if [ "$_erv" = 0 ]; then echo no; else echo yes; fi
}
# wr_validate_paths: D1-D6, run on the resolved W (WR_W_RES), B (WR_B_RES) and C (WR_C_RES), before any directory is made
wr_validate_paths() {
  _fw=$(wr_fold "$WR_W_RES") || { echo "cannot read the run folder name" >&2; return 2; }
  _fb=$(wr_fold "$WR_B_RES") || { echo "cannot read the board name" >&2; return 2; }
  _fc=$(wr_fold "$WR_C_RES") || { echo "cannot read the config file name" >&2; return 2; }
  # D1 a Claude Code settings name
  for _d1 in "${_fw##*/}" "${_fb##*/}"; do
    case "$_d1" in settings.json|settings.[l]ocal.json|managed-settings.json|.claude.json)
      { echo "the run folder or the board is named like a Claude Code settings file ($_d1); choose another name" >&2; return 2; } ;; esac
  done
  # D2 the Claude Code config folder itself (a subfolder of it stays legal)
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then _cfg=$CLAUDE_CONFIG_DIR
  else case "${HOME:-}" in /*) _cfg="${HOME%/}/.claude" ;; *) _cfg="" ;; esac; fi
  case "$_cfg" in /*) ;; *) { echo "cannot locate the Claude Code config folder; set CLAUDE_CONFIG_DIR absolute" >&2; return 2; } ;; esac
  wr_resolve "$_cfg" dir || { echo "cannot locate the Claude Code config folder ('$_cfg' $_WR_WHY); set CLAUDE_CONFIG_DIR absolute" >&2; return 2; }
  _fk=$(wr_fold "$_WR_RES") || { echo "cannot read the Claude Code config folder name" >&2; return 2; }
  [ "$_fw" != "$_fk" ] || { echo "WARROOM_DIR is the Claude Code config folder ($WR_W_RES); use a dedicated subfolder or a path outside it" >&2; return 2; }
  # D5 shapes that make the board and the run folder the same thing or nest them the wrong way round
  [ "$_fb" != "$_fw" ] || { echo "the board is the run folder ($WR_W_RES); BOARD must name a file" >&2; return 2; }
  case "$_fw/" in "$_fb"/*) { echo "the board ($WR_B_RES) is a folder above the run folder; bootstrap would make it a directory" >&2; return 2; } ;; esac
  # D3 a board at a reserved state name, at any depth below the run folder; a board never ends in .flock
  if wr_reserved_below "$_fw" "$_fb"; then { echo "the board ($WR_B_RES) is at a name this tool writes inside the run folder (seats.tsv, pids.tsv, .cursor-*, .lastwake-*, .anchor-*, .guard-*, .poll-*, .snap-*, .wrtmp.*, *.flock, *.tmp.<digits>, *.chunk.<digits>); choose another name" >&2; return 2; }; fi
  case "${_fb##*/}" in *.flock) { echo "the board ($WR_B_RES) ends in .flock, which is the lock-file name; choose another name" >&2; return 2; } ;; esac
  # D4 the board or the run folder is the config file; an existing board is the same file as the config or as a state entry
  [ "$_fb" != "$_fc" ] || { echo "the board is the config file ($WR_C_RES)" >&2; return 2; }
  [ "$_fw" != "$_fc" ] || { echo "the run folder is the config file ($WR_C_RES)" >&2; return 2; }
  _fv=$(wr_same "$WR_B_RES" "$WR_C_SEL") || { echo "cannot compare the board ($WR_B_RES) with the config file" >&2; return 2; }
  [ "$_fv" = 0 ] || { echo "the board is the same file as the config file" >&2; return 2; }
  _fv=$(wr_ef_reserved "$WR_B_RES") || { echo "cannot compare the board ($WR_B_RES) with the state entries of the run folder" >&2; return 2; }
  [ "$_fv" = no ] || { echo "the board is the same file as a state entry of the run folder" >&2; return 2; }
  # D6 the config file at a name this tool writes (it exists or not), or the same file as one that does
  if wr_reserved_below "$_fw" "$_fc"; then { echo "the config file ($WR_C_RES) is at a name this tool writes inside the run folder; move warroom.env" >&2; return 2; }; fi
  case "${_fc##*/}" in *.flock) { echo "the config file ($WR_C_RES) ends in .flock, which is the lock-file name; move warroom.env" >&2; return 2; } ;; esac
  [ "$_fc" != "$_fb.flock" ] || { echo "the config file is the board's lock file ($WR_C_RES)" >&2; return 2; }
  _fv=$(wr_same "$WR_C_SEL" "$WR_B_RES.flock") || { echo "cannot compare the config file ($WR_C_SEL) with the board's lock file" >&2; return 2; }
  [ "$_fv" = 0 ] || { echo "the config file is the same file as the board's lock file" >&2; return 2; }
  _fv=$(wr_ef_reserved "$WR_C_SEL") || { echo "cannot compare the config file ($WR_C_SEL) with the state entries of the run folder" >&2; return 2; }
  [ "$_fv" = no ] || { echo "the config file is the same file as a state entry of the run folder" >&2; return 2; }
  return 0
}
# wr_seat_arg SEAT [EXTRA]: a seat name that becomes part of a path must be in SEATS; exit 2 before any per-seat lock, temp or write
wr_seat_arg() {
  wr_seat_ok "$1" && return 0
  echo "unknown seat '$1' (seats: $SEATS${2:-})" >&2; exit 2
}
# --- Writing state: create, temp, replace, stamp -------------------------------------------------------------------
# Data and state files are made and changed through these four functions. Each caller copies the result of wr_temp into its own
# variable at once, so one helper never overwrites the temp another caller recorded.
# wr_statnum GNUFMT BSDFMT FILE: the number stat reports for FILE, or status 1 with nothing printed. A number is a plain
# decimal of 1 to 15 digits with no leading zero and not zero (an inode, a link count and a modification time are never 0),
# so a failed or odd answer is never turned into a default. The form is chosen by the system, not by trying one and then the
# other: bash's OSTYPE names the BSD family (macOS included), which takes `stat -f`; everything else takes `stat -c`. (On
# Linux `stat -f` means "file system status" and prints several lines.) macOS with GNU coreutils' stat ahead of /usr/bin on
# the PATH is not supported: put /usr/bin first.
wr_statnum() {
  case "${OSTYPE:-}" in
    darwin*|freebsd*|netbsd*|openbsd*|dragonfly*) _sn=$(stat -f "$2" "$3" 2>/dev/null) || return 1 ;;
    *) _sn=$(stat -c "$1" "$3" 2>/dev/null) || return 1 ;;
  esac
  case "$_sn" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#_sn}" -le 15 ] || return 1
  printf '%s\n' "$_sn"
}
_wr_links() { wr_statnum %h %l "$1"; }   # FILE -> its link count; status 1 and nothing printed if it cannot be read
# wr_absent FILE: prints yes only when FILE is genuinely absent: it is not there, it is not a (dangling) link, and the folder
# that would hold it is a folder this process can search, else no; status 1 and nothing printed when that cannot be told. "-e says no" alone is also what a folder we cannot search, a parent that is a
# file and a link loop look like, so those are status 1 (cannot tell), never "absent".
wr_absent() {
  _wa=$(wr_kind "$1") || return 1
  if [ "$_wa" != absent ]; then echo no; return 0; fi
  case "$1" in */*) _wr_ad=${1%/*}; [ -n "$_wr_ad" ] || _wr_ad=/ ;; *) _wr_ad=. ;; esac
  _wa=$(wr_kind "$_wr_ad" follow) || return 1
  if [ "$_wa" = dir ]; then echo yes; else echo no; fi
}
# wr_leaf_ok FILE: 0 when FILE is a regular file with one name and is not a link
wr_leaf_ok() { _wl=$(wr_kind "$1") || return 1; [ "$_wl" = file ] || return 1; _wl=$(_wr_links "$1") || return 1; [ "$_wl" = 1 ]; }
# wr_registry_read FILE: the rows of a registry (one text file) on stdout. A registry that is genuinely absent is an empty
# registry (status 0, nothing printed); one that cannot be read, or is not a regular file with one name, is status 1 with
# nothing printed. The whole file is read before anything is printed, so a read that fails halfway prints no rows.
wr_registry_read() {
  _wr_ab=$(wr_absent "$1") || return 1
  if [ "$_wr_ab" = yes ]; then return 0; fi
  wr_leaf_ok "$1" || return 1
  _wr_rg=$(cat -- "$1") || return 1
  [ -z "$_wr_rg" ] || printf '%s\n' "$_wr_rg"
}
# wr_col N ROW: column N of a tab separated ROW held in memory; status 1 and nothing printed when the cut fails
wr_col() { _wr_c=$( set -o pipefail; printf '%s' "$2" | cut -f"$1" ) || return 1; printf '%s\n' "$_wr_c"; }
# wr_ncols ROW: the number of tab separated columns of ROW; status 1 and nothing printed when the count fails
wr_ncols() { _wr_n=$( set -o pipefail; printf '%s' "$1" | awk -F'\t' '{print NF}' ) || return 1; printf '%s\n' "$_wr_n"; }
# wr_create FILE: make an empty FILE with a noclobber create (it never truncates a regular file, and it fails on an existing
# regular file or a dangling link; a non-regular entry planted at the name is outside this tool's scope and is refused by the recheck). An existing entry, or a lost race, is accepted only when it is a regular file with one name.
wr_create() {
  _wc=$(wr_kind "$1") || { echo "could not examine $1" >&2; return 1; }
  case "$_wc" in
    link) echo "$1 is a symlink; a protected file has one name" >&2; return 1 ;;
    absent) ( set -C; : > "$1" ) 2>/dev/null && return 0 ;;
  esac
  _wc=$(wr_kind "$1") || { echo "could not examine $1" >&2; return 1; }
  if [ "$_wc" != absent ]; then
    wr_leaf_ok "$1" || { echo "$1 exists and is not a regular file with one name; refusing to use it" >&2; return 1; }
    return 0
  fi
  echo "could not create $1" >&2; return 1
}
# wr_temp FINAL: make an exclusive temp file (mode 0600) in FINAL's folder. _WR_TMP holds its name; on failure _WR_TMP is empty,
# the return is 1, and the caller writes, replaces and cleans up nothing under any temp name.
wr_temp() {
  _WR_TMP=""
  case "$1" in */*) _wr_td=${1%/*}; [ -n "$_wr_td" ] || _wr_td=/ ;; *) _wr_td=. ;; esac
  _wr_tn=$(mktemp "$_wr_td/.wrtmp.XXXXXXXX" 2>/dev/null) || return 1
  [ -n "$_wr_tn" ] && [ -f "$_wr_tn" ] || return 1
  _WR_TMP=$_wr_tn
}
# wr_drop TMP: remove a temp this caller made and recorded (only a .wrtmp.* name, never a final name). A temp that cannot be
# removed is reported with its path. Safe to call twice and with an empty name.
wr_drop() {
  [ -n "${1:-}" ] || return 0
  case "${1##*/}" in .wrtmp.*) ;; *) return 0 ;; esac
  rm -f -- "$1" 2>/dev/null && return 0
  echo "could not remove the temporary file $1; it is left in place" >&2; return 1
}
# wr_replace TMP FINAL: rename TMP over FINAL (rename(2): a directory at FINAL is an error, not a move into it). FINAL, when it
# exists, must be a regular file with one name. On refusal or failure FINAL is untouched, only the recorded TMP is removed (a
# removal that fails is reported with the temp's path) and the return is 1. After a process crash FINAL is the old file or the
# new one (rename); there is no fsync and no power-loss guarantee.
wr_replace() {
  _wr_rt=$1; _wr_rf=$2
  _wr_rk=$(wr_kind "$_wr_rf") || { echo "refusing to replace $_wr_rf: it cannot be examined" >&2; wr_drop "$_wr_rt"; return 1; }
  if [ "$_wr_rk" != absent ]; then
    wr_leaf_ok "$_wr_rf" || { echo "refusing to replace $_wr_rf: it must be a regular file with one name" >&2; wr_drop "$_wr_rt"; return 1; }
  fi
  _wr_re=$(python3 -I -S -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' "$_wr_rt" "$_wr_rf" 2>&1) && return 0
  echo "could not replace $_wr_rf: ${_wr_re##*: }" >&2; wr_drop "$_wr_rt"; return 1
}
# wr_stamp FILE: the gap marker. Create (exclusive, checked) and touch; a failed touch can still leave a fresh file with a fresh time.
wr_stamp() { wr_create "$1" || return 1; touch -- "$1"; }
# wr_startup: resolve and check the three paths, read warroom.env, set SEATS, W, BOARD, BOARD_FILE and BOSS_SEAT, make the board.
# A problem is said on stderr and is status 2; the dispatch below turns that into the exit status for this caller.
wr_startup() {
  wr_need_python || return 2
  WR_C_SEL=$(wr_config_path) || { echo "cannot work out where warroom.env is" >&2; return 2; }
  if [ -z "${WARROOM_ENV:-}" ]; then case "${HOME:-}" in /*) ;; *) { echo "cannot locate warroom.env: HOME is not an absolute path (set WARROOM_ENV to an absolute path)" >&2; return 2; } ;; esac; fi
  case "$WR_C_SEL" in /*) ;; *) { echo "WARROOM_ENV must be an absolute path (got '$WR_C_SEL')" >&2; return 2; } ;; esac
  wr_resolve "$WR_C_SEL" input || { echo "the config file '$WR_C_SEL' $_WR_WHY" >&2; return 2; }
  WR_C_RES=$_WR_RES
  # shellcheck disable=SC2034  # WR_ENV_FILE and BOSS_SEAT are read by the scripts that source this file
  WR_ENV_FILE=$WR_C_SEL
  _ke=$(wr_kind "$WR_ENV_FILE" follow) || { echo "cannot examine the config file '$WR_ENV_FILE'" >&2; return 2; }
  # only a name that leads nowhere at all means "no config, use the defaults": a link that leads nowhere, a folder or
  # anything else that is not a regular file is a mistake in the setup and is said
  if [ "$_ke" = absent ]; then
    _kl=$(wr_kind "$WR_ENV_FILE") || { echo "cannot examine the config file '$WR_ENV_FILE'" >&2; return 2; }
    [ "$_kl" != link ] || { echo "the config file '$WR_ENV_FILE' is a link that leads nowhere; point it at a file or remove it" >&2; return 2; }
  fi
  case "$_ke" in
    file) wr_load_config "$WR_ENV_FILE" || return 2 ;;
    absent) WR_ENV_FILE="" ;;
    *) echo "the config file '$WR_ENV_FILE' is not a regular file (it is a $_ke)" >&2; return 2 ;;
  esac
  SEATS=${SEATS:-"BOSS MANAGER W1 W2"}
  wr_seats_ok "$SEATS" || { echo "SEATS='$SEATS': names are [A-Z][A-Z0-9_]{0,15}, no repeats; ALL, NONE and GUARD are reserved" >&2; return 2; }
  if [ -z "${WARROOM_DIR:-}" ]; then
    case "${HOME:-}" in /*) WARROOM_DIR="${HOME%/}/warroom-run" ;; *) { echo "WARROOM_DIR is not set and HOME is not an absolute path; set WARROOM_DIR to an absolute path" >&2; return 2; } ;; esac
  fi
  case "$WARROOM_DIR" in /*) ;; *) { echo "WARROOM_DIR must be an absolute path (got '$WARROOM_DIR')" >&2; return 2; } ;; esac
  wr_resolve "$WARROOM_DIR" dir || { echo "WARROOM_DIR '$WARROOM_DIR' $_WR_WHY" >&2; return 2; }
  WR_W_RES=$_WR_RES
  W=${WARROOM_DIR%/}
  BOARD=${BOARD:-board.md}
  case "$BOARD" in
    /*) BOARD_FILE="$BOARD" ;;
    *) case "/$BOARD/" in */./*|*/../*) { echo "BOARD must not contain . or .. components; write board.md" >&2; return 2; } ;; esac
       BOARD_FILE="$W/$BOARD" ;;
  esac
  wr_resolve "$BOARD_FILE" file || { echo "BOARD '$BOARD_FILE' $_WR_WHY" >&2; return 2; }
  WR_B_RES=$_WR_RES
  wr_validate_paths || return 2
  readonly W BOARD_FILE WR_W_RES WR_B_RES WR_C_SEL WR_C_RES
  # Create a missing board with an exclusive create, which never truncates: two scripts that both find it missing must not
  # erase each other's first post (the one that loses the race accepts the winner's file). If the run directory or the board
  # cannot be created, say so and stop (a hook exits 1, not 2).
  mkdir -p "$W" 2>/dev/null
  _kb=$(wr_kind "$BOARD_FILE") || { echo "cannot examine the board $BOARD_FILE" >&2; return 2; }
  if [ "$_kb" = absent ]; then
    _bd=$(dirname "$BOARD_FILE") || { echo "cannot work out the folder of the board $BOARD_FILE" >&2; return 2; }
    mkdir -p "$_bd" 2>/dev/null
    wr_create "$BOARD_FILE" || { echo "cannot create the board $BOARD_FILE" >&2; return 2; }
  fi
  # shellcheck disable=SC2034
  BOSS_SEAT=${SEATS%% *}
}
if [ "$WR_CONFIG_EXIT" = 1 ]; then wr_startup || exit 1; else wr_startup || exit 2; fi

wr_now()   { date +%H:%M; }
# wr_epoch — the clock in seconds, as a canonical decimal (1-15 digits, no leading zero) or status 1 with nothing printed
wr_epoch() { _we=$(date +%s) || return 1; case "$_we" in ''|0*|*[!0-9]*) return 1 ;; esac; [ "${#_we}" -le 15 ] || return 1; printf '%s\n' "$_we"; }
# wr_hhmm T — T is a real clock time: HH:MM with HH 00-23 and MM 00-59 (checked before any arithmetic on it)
wr_hhmm() { case "$1" in [0-9][0-9]:[0-9][0-9]) [ "$((10#${1%%:*}))" -lt 24 ] && [ "$((10#${1##*:}))" -lt 60 ] ;; *) return 1 ;; esac; }
wr_mtime() { wr_statnum %Y %m "$1"; }   # FILE -> its modification time in seconds; status 1 and nothing printed if it cannot be read
wr_seat_ok() { case " $SEATS " in *" $1 "*) return 0 ;; esac; return 1; }
# --- The writer lock -----------------------------------------------------------------------------------------------
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
_WR_SLOT8=""; _WR_SLOT9=""; _WR_ARG8=""; _WR_ARG9=""
_wr_path() { # FILE -> _WR_KEY = physical parent folder + base name (no checks)
  case "$1" in */*) _wr_dn=${1%/*}; [ -n "$_wr_dn" ] || _wr_dn=/ ;; *) _wr_dn=. ;; esac
  _wr_d=$(cd -P -- "$_wr_dn" 2>/dev/null && pwd -P) || return 1
  # Bash 3.2 puts text left over from an earlier failed builtin write in front of what a $( ) prints: the folder is the last line.
  # The class: a `$( cd ... && pwd )` capture that runs AFTER a builtin write has failed in the same shell (echo, printf or a
  # redirect on a closed stdout). Here that is possible (error branches call this resolver), so the answer is cut to its last
  # line. The other `cd -P ... && pwd` captures (WR_ROOT above, wr_resolve, which only the startup checks call, each entry
  # script's HERE and the BIN of the waiter-check hook) run during entry setup and the startup checks. No failed builtin write
  # can precede them on a path that goes on (an earlier diagnostic exits). Startup may already have created the board, but that
  # is a file create, not a builtin write to the shell's own output, so it leaves no stale text. A new capture of this shape
  # after a write needs the same cut.
  _wr_d=${_wr_d##*$'\n'}
  [ -d "$_wr_d" ] || return 1
  _WR_KEY="$_wr_d/${1##*/}"
}
_wr_sub_ok() { # every lock function refuses inside a subshell, before it touches anything
  [ "${BASH_SUBSHELL:-0}" = 0 ] && return 0
  echo "lock used from a subshell ($1 $2): lock and unlock at the top level of a script or in its functions" >&2; return 2
}
wr_lock() {
  _wr_sub_ok wr_lock "$1" || return 2
  _wr_path "$1" || { echo "could not open lock file for $1: its folder cannot be resolved" >&2; return 1; }
  _wr_k=$_WR_KEY
  _wr_kk=$(wr_kind "$_wr_k") || { echo "could not open lock file for $1: it cannot be examined" >&2; return 1; }
  if [ "$_wr_kk" = link ]; then echo "$1 is a symlink; point the war room at the real path (a protected file has one name)" >&2; return 2; fi
  if [ "$_wr_kk" != absent ]; then
    _wr_c=$(_wr_links "$_wr_k") || { echo "could not open lock file for $1: its link count cannot be read" >&2; return 1; }
    [ "$_wr_c" -le 1 ] || { echo "$1 has $_wr_c hard links; a protected file must have exactly one name" >&2; return 2; }
  fi
  _wr_kk=$(wr_kind "$_wr_k.flock") || { echo "could not open lock file for $1: $_wr_k.flock cannot be examined" >&2; return 1; }
  if [ "$_wr_kk" = link ]; then echo "lock file $_wr_k.flock is a symlink; refusing to lock through it" >&2; return 2; fi
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
    if [ "$_wr_fd" = 8 ]; then _WR_SLOT8=$_wr_k; _WR_ARG8=$1; else _WR_SLOT9=$_wr_k; _WR_ARG9=$1; fi
    return 0
  fi
  if [ "$_wr_fd" = 8 ]; then exec 8>&-; else exec 9>&-; fi    # failed: close only the descriptor just opened
  if [ "$_wr_rc" = 1 ]; then echo "could not lock $1: held by another writer for ${_wr_w}s" >&2
  else echo "lock helper failed for $1: ${_wr_e:-no message} (exit $_wr_rc)" >&2; fi
  return 1
}
wr_unlock() {
  _wr_sub_ok wr_unlock "$1" || return 2
  # The name given to wr_lock releases with no command substitution: after a failed builtin write bash still holds that text,
  # and the next builtin that writes inside $( ) would flush it into the captured path and the key would no longer match.
  if [ -n "$_WR_SLOT8" ] && [ "$_WR_ARG8" = "$1" ]; then exec 8>&-; _WR_SLOT8=""; _WR_ARG8=""; return 0; fi
  if [ -n "$_WR_SLOT9" ] && [ "$_WR_ARG9" = "$1" ]; then exec 9>&-; _WR_SLOT9=""; _WR_ARG9=""; return 0; fi
  _wr_path "$1" || { echo "could not release the lock for $1: its folder cannot be resolved; it is held until this shell ends" >&2; return 1; }
  if [ -n "$_WR_SLOT8" ] && [ "$_WR_SLOT8" = "$_WR_KEY" ]; then exec 8>&-; _WR_SLOT8=""; _WR_ARG8=""
  elif [ -n "$_WR_SLOT9" ] && [ "$_WR_SLOT9" = "$_WR_KEY" ]; then exec 9>&-; _WR_SLOT9=""; _WR_ARG9=""; fi
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
# ONE implementation of "what ps says about when a process started", used by wr_started and by wr_proc (the same source text is
# handed to Python in both): ps is read as bytes and decoded strictly as ASCII (a non-ASCII byte is refused; a NUL is ASCII and is refused by the full match below)
# (bash $( ) would drop a NUL without a word); blanks are squeezed to single spaces; the result must be one start time such as
# "Mon Nov 2 10:00:00 2026" (weekday and month names, day 1-31, hour 0-23, minute and second 0-59, a four-digit year).
# start_of(pid) returns that text, or None when ps failed or printed anything else.
_WR_PYSTART='import re, subprocess
_RE = re.compile(r"(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] [0-9]{4}")
def start_of(pid):
    try: r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError: return None
    if r.returncode != 0: return None
    try: text = r.stdout.decode("ascii").rstrip("\n")
    except UnicodeDecodeError: return None
    out = " ".join(w for w in text.split(" ") if w)
    return out if _RE.fullmatch(out) else None'
# wr_started PID: print the start time of PID; exit 1 (nothing printed) when it cannot be read.
wr_started() {
  _wr_st=$(LC_ALL=C python3 -I -S -c "$_WR_PYSTART"$'\n''import sys
try: s = start_of(int(sys.argv[1]))
except ValueError: s = None
if s is None: sys.exit(1)
print(s)' "$1" 2>/dev/null 8>&- 9>&-) || return 1     # no lock copy in the helper; a failed read prints nothing
  [ -n "$_wr_st" ] || return 1
  printf '%s\n' "$_wr_st"
}
# wr_rowproc PID STARTED COLS: judge a recorded row. Like wr_proc, except that a row of five or more columns whose start
# column is EMPTY (ps could not read it when the row was written) is never alive: a live pid with no recorded start time is
# unknown, a dead one is dead. Only an old four-column row (COLS < 5) is judged by the pid alone.
wr_rowproc() {
  if [ -z "${2:-}" ] && [ "${3:-0}" -ge 5 ]; then
    _wr_rv=$(wr_proc "$1") || return 1
    case "$_wr_rv" in dead) echo dead ;; *) echo unknown ;; esac
  else wr_proc "$1" "${2:-}"; fi
}
# wr_proc PID [STARTED]: print one word.
#   dead     the kernel says no such process (ESRCH), or (when STARTED is given) the pid now belongs to a process that
#            started at another time
#   alive    the process exists and, when STARTED is given, started at that time; with no STARTED the pid alone decides
#   unknown  the process exists but its start time cannot be read (ps failed or printed something that is not a start time),
#            kill -0 was refused for any reason other than "no such process" (a process of another owner), or PID is not a
#            plain positive number: it is neither alive nor dead. Callers
#            keep what they hold and say so; they never treat unknown as dead.
wr_proc() {
  # a pid that is not a plain positive number is not a process that was seen to be gone: unknown, never dead
  case "$1" in ''|*[!0-9]*|?????????????*) echo unknown; return 0 ;; esac
  [ "$((10#$1))" -gt 0 ] || { echo unknown; return 0; }       # pid 0 would mean the whole process group
  _wr_pp=$(LC_ALL=C python3 -I -S -c "$_WR_PYSTART"$'\n''import os, sys
pid = int(sys.argv[1])
def state():
    try: os.kill(pid, 0)
    except (ProcessLookupError, OverflowError): return "dead"
    except OSError: return "unknown"
    return "alive"
a = state()
if a != "alive" or len(sys.argv) < 3: print(a); sys.exit(0)
out = start_of(pid)
if out is not None: print("alive " + out); sys.exit(0)
print("dead" if state() == "dead" else "unknown")' "$1" ${2:+x}) || return 1
  case "$_wr_pp" in
    dead|unknown|alive) echo "$_wr_pp"; return 0 ;;
    "alive "*) ;;
    *) return 1 ;;
  esac
  if [ "${_wr_pp#alive }" = "$2" ]; then echo alive; else echo dead; fi
}
