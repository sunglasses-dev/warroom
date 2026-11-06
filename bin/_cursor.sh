# shellcheck shell=bash
# bin/_cursor.sh — read positions in the board that survive a rotation, a truncation and a new day. Sourced after _common.sh.
# A cursor file holds "GENERATION LINE EPOCH SUM". GENERATION is the board's inode plus a checksum of its first line;
# SUM is the checksum and byte length of the whole consumed prefix (lines 1 to LINE, "crc-bytes"; 0 for LINE 0). A reader
# resumes only when the board is the same file AND everything it has already read is still byte for byte the same, so a
# board that was emptied or edited in place and filled again (same inode, same first line, same line at the reader's
# position, a new line somewhere in the part already read) is noticed and read again from its start.
# Supported ways to rotate a board: move it away (mv board.md board.old, then start a new file: new inode), or empty it
# and let it fill again. A cursor written by an older version holds the checksum of the last line only; it is still
# accepted once, and every cursor written from now on carries the prefix sum.
wr_inode() { wr_statnum %i %i "$1"; }   # FILE -> its inode number; status 1 and nothing printed if it cannot be read
# The checksum functions report a failed read or a failed stage of their pipeline (pipefail inside a subshell), never a sum
# of whatever arrived. A caller that gets a nonzero status consumes nothing.
wr_generation() {
  _gi=$(wr_inode "$1") || return 1; _gs=$( set -o pipefail; head -n 1 "$1" 2>/dev/null | cksum | cut -d' ' -f1 ) || return 1
  [ -n "$_gs" ] || return 1
  echo "$_gi:$_gs"
}
wr_sum() { ( set -o pipefail; cksum | cut -d' ' -f1 ); }                       # checksum of stdin
# wr_sumstdin — "crc-bytes" of stdin (the byte length makes a collision in the crc alone not enough)
wr_sumstdin() { ( set -o pipefail; cksum | awk '{print $1 "-" $2}' ); }
# wr_prefixsum BOARD N — "crc-bytes" of lines 1 to N (N = 0: the empty prefix, 0); nothing is printed when the read fails
wr_prefixsum() {
  case "$2" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$2" -gt 0 ] || { echo 0; return 0; }
  _ps=$( set -o pipefail; head -n "$2" "$1" 2>/dev/null | wr_sumstdin ) || return 1
  [ -n "$_ps" ] || return 1
  echo "$_ps"
}
# wr_linesum BOARD N — checksum of line N alone (only to read a cursor written by an older version); nothing is printed and
# the status is 1 when the read or the checksum fails
wr_linesum() {
  case "$2" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$2" -gt 0 ] || { echo 0; return 0; }
  _ls=$( set -o pipefail; sed -n "${2}p;${2}q" "$1" 2>/dev/null | wr_sum ) || return 1
  [ -n "$_ls" ] || return 1
  echo "$_ls"
}
# wr_lines FILE — the number of lines in FILE; nothing is printed and the status is 1 when the count fails or is not a number
# (a failed count is "cannot read", never "the board is empty" or "the board changed")
wr_lines() {
  _wl=$( set -o pipefail; wc -l < "$1" 2>/dev/null | tr -d ' ' ) || return 1
  case "$_wl" in ''|*[!0-9]*) return 1 ;; esac
  echo "$_wl"
}
# wr_digits X — status 0 when X is one or more digits and nothing else
wr_digits() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# wr_canon N — status 0 when N is a canonical decimal: "0", or 1 to 15 digits with no leading zero (no wrap in the shell's
# arithmetic, no octal reading of "08")
wr_canon() {
  case "$1" in
    0) return 0 ;;
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 15 ]
}
# wr_cursor_parse FILE — status 0 and the three or four fields in _g _l _t _s when FILE holds exactly one newline-ended
# record of the current grammar: GEN = digits ":" digits (the board's inode and the checksum of its first line), LINES and
# EPOCH canonical decimals, each checked on its own, SUM absent (three fields, a cursor from the oldest version), digits
# (the last line only) or digits "-" digits (the consumed prefix). Anything else is status 1 and a line on stderr naming
# the file and the first rule it breaks; nothing is printed on stdout.
wr_cursor_parse() {
  _g=""; _l=""; _t=""; _s=""; _px=""; _pn=""; _pr=""; _pq=""
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || { echo "cursor $1 is not a readable regular file" >&2; return 1; }
  { IFS=' ' read -r _g _l _t _s _px; _pr=$?; IFS= read -r _pn; _pq=$?; } < "$1" 2>/dev/null
  [ "$_pr" = 0 ] || { echo "cursor $1 is empty, has no final newline or could not be read" >&2; return 1; }
  { [ "$_pq" = 1 ] && [ -z "$_pn" ]; } || { echo "cursor $1 is not exactly one line" >&2; return 1; }
  [ -z "$_px" ] || { echo "cursor $1 has more than four fields" >&2; return 1; }
  wr_digits "${_g%%:*}" && wr_digits "${_g#*:}" && case "$_g" in *:*:*) false ;; *:*) true ;; *) false ;; esac \
    || { echo "cursor $1: the generation is not digits:digits" >&2; return 1; }
  wr_canon "$_l" || { echo "cursor $1: the line count is not a canonical decimal" >&2; return 1; }
  wr_canon "$_t" || { echo "cursor $1: the time is not a canonical decimal" >&2; return 1; }
  case "$_s" in
    '') ;;
    *-*) wr_digits "${_s%%-*}" && wr_digits "${_s#*-}" || { echo "cursor $1: the checksum is not digits-digits" >&2; return 1; } ;;
    *) wr_digits "$_s" || { echo "cursor $1: the checksum is not digits" >&2; return 1; } ;;
  esac
  return 0
}
# wr_cursor_get CURSOR_FILE BOARD MAX_AGE_SECONDS
#   prints the line to resume from; 0 when the board was replaced, shrank or changed in the part already read (all of it
#   is new to this reader); "none" when there is no cursor (first run: the file is absent and its folder can be searched)
#   or the cursor is valid but older than MAX_AGE_SECONDS. A cursor that is unreadable, not of the grammar above, or dated
#   more than a day ahead of the clock is corrupt, never "none": nothing is printed and the status is 1, and the caller
#   consumes nothing. A checksum that cannot be computed is not "the board changed": same, status 1.
wr_cursor_get() {
  _cg=""; _cs=""; _cn=""
  if wr_absent "$1"; then echo none; return 0; fi          # a missing cursor is normal on the first arm: say nothing
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then echo "cursor $1: its folder cannot be searched, so it is not known to be absent" >&2; return 1; fi
  wr_cursor_parse "$1" || return 1
  _cn=$(wr_epoch) || { echo "cursor $1: could not read the clock" >&2; return 1; }
  [ "$_t" -le $(( _cn + 86400 )) ] || { echo "cursor $1: its time is more than a day ahead of the clock" >&2; return 1; }
  [ $(( _cn - _t )) -le "${3:-86400}" ] || { echo none; return 0; }
  _cg=$(wr_generation "$2") || return 1
  if [ "$_g" = "$_cg" ]; then
    _n=$(wr_lines "$2") || return 1
    if [ "$_l" -le "$_n" ]; then
      if [ "$_l" -eq 0 ] || [ -z "$_s" ]; then echo "$_l"; return 0; fi    # nothing read yet, or a cursor without SUM (accepted once)
      case "$_s" in
        *-*) _cs=$(wr_prefixsum "$2" "$_l") || return 1 ;;
        *)   _cs=$(wr_linesum "$2" "$_l") || return 1 ;;                   # older cursor: the last line only
      esac
      [ "$_s" = "$_cs" ] && { echo "$_l"; return 0; }
    fi
  fi
  echo 0
}
# wr_cursor_put CURSOR_FILE GENERATION LINE SUM — GENERATION is read before the line count, so a rotation in between is
# noticed at the next read (it can repeat a line, never skip one). SUM is the prefix sum of lines 1 to LINE as the reader
# read them. Written to a temp file in the cursor's folder, then renamed over the cursor (wr_temp, wr_replace). Returns non-zero
# when the temp, the write or the rename fails; the cursor is then as it was, and only a temp this call made is removed (a
# removal that fails is reported with the temp's path). Callers check the result before they report a read or a wake.
wr_cursor_put() {
  _cp=$(wr_epoch) || { echo "could not read the clock: the cursor $1 was not written" >&2; return 1; }
  wr_temp "$1" || { echo "could not create a temporary file next to $1" >&2; return 1; }
  _cur_t=$_WR_TMP
  if printf '%s %s %s %s\n' "$2" "$3" "$_cp" "${4:-0}" > "$_cur_t"; then wr_replace "$_cur_t" "$1"; return; fi
  wr_drop "$_cur_t"; return 1
}
