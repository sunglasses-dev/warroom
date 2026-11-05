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
wr_inode() {
  _ino=$(stat -c %i "$1" 2>/dev/null) || _ino=$(stat -f %i "$1" 2>/dev/null) || _ino=0
  case "$_ino" in ''|*[!0-9]*) _ino=0 ;; esac
  echo "$_ino"
}
# The checksum functions report a failed read or a failed stage of their pipeline (pipefail inside a subshell), never a sum
# of whatever arrived. A caller that gets a nonzero status consumes nothing.
wr_generation() {
  _gi=$(wr_inode "$1"); _gs=$( set -o pipefail; head -n 1 "$1" 2>/dev/null | cksum | cut -d' ' -f1 ) || return 1
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
  if [ "$2" -gt 0 ]; then ( set -o pipefail; sed -n "${2}p;${2}q" "$1" 2>/dev/null | wr_sum ); else echo 0; fi
}
# wr_cursor_get CURSOR_FILE BOARD MAX_AGE_SECONDS
#   prints the line to resume from; 0 when the board was replaced, shrank or changed in the part already read (all of it
#   is new to this reader); "none" when there is no usable cursor (first run, unreadable, or older than MAX_AGE_SECONDS).
#   A checksum that cannot be computed is not "the board changed": nothing is printed and the status is 1, and the caller
#   consumes nothing.
wr_cursor_get() {
  _g=""; _l=""; _t=""; _s=""; _cg=""; _cs=""
  [ -r "$1" ] || { echo none; return; }                     # a missing cursor is normal on the first arm: say nothing
  read -r _g _l _t _s < "$1" 2>/dev/null || { echo none; return; }
  case "$_l$_t" in ''|*[!0-9]*) echo none; return ;; esac
  [ $(( $(date +%s) - _t )) -le "${3:-86400}" ] || { echo none; return; }
  _cg=$(wr_generation "$2") || return 1
  if [ "$_g" = "$_cg" ]; then
    _n=$(wc -l < "$2" | tr -d ' ')
    if [ "$_l" -le "$_n" ]; then
      if [ "$_l" -eq 0 ] || [ -z "$_s" ]; then echo "$_l"; return; fi     # nothing read yet, or a cursor without SUM (accepted once)
      case "$_s" in
        *-*) _cs=$(wr_prefixsum "$2" "$_l") || return 1 ;;
        *)   _cs=$(wr_linesum "$2" "$_l") || return 1 ;;                   # older cursor: the last line only
      esac
      [ "$_s" = "$_cs" ] && { echo "$_l"; return; }
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
  wr_temp "$1" || { echo "could not create a temporary file next to $1" >&2; return 1; }
  _cur_t=$_WR_TMP
  if printf '%s %s %s %s\n' "$2" "$3" "$(date +%s)" "${4:-0}" > "$_cur_t"; then wr_replace "$_cur_t" "$1"; return; fi
  wr_drop "$_cur_t"; return 1
}
