# shellcheck shell=bash
# bin/_cursor.sh — read positions in the board that survive a rotation, a truncation and a new day. Sourced after _common.sh.
# A cursor file holds "GENERATION LINE EPOCH SUM". GENERATION is the board's inode plus a checksum of its first line;
# SUM is the checksum of the last line the reader consumed (line number LINE). A reader resumes only when the board is
# the same file AND the line it stopped at is still the same line, so a board that was emptied in place and refilled
# (same inode, same first line, already longer than before) is noticed and read again from its start.
# Supported ways to rotate a board: move it away (mv board.md board.old, then start a new file: new inode), or empty it
# and let it fill again. Not noticed: a rewrite that leaves the line at the reader's position byte for byte the same.
wr_inode() {
  _ino=$(stat -c %i "$1" 2>/dev/null) || _ino=$(stat -f %i "$1" 2>/dev/null) || _ino=0
  case "$_ino" in ''|*[!0-9]*) _ino=0 ;; esac
  echo "$_ino"
}
wr_generation() { echo "$(wr_inode "$1"):$(head -n 1 "$1" 2>/dev/null | cksum | cut -d' ' -f1)"; }
wr_sum() { cksum | cut -d' ' -f1; }                       # checksum of stdin
# wr_linesum BOARD N — checksum of line N (N = 0: the empty prefix, 0)
wr_linesum() {
  case "$2" in ''|*[!0-9]*) echo 0; return ;; esac
  if [ "$2" -gt 0 ]; then sed -n "${2}p;${2}q" "$1" 2>/dev/null | wr_sum; else echo 0; fi
}
# wr_cursor_get CURSOR_FILE BOARD MAX_AGE_SECONDS
#   prints the line to resume from; 0 when the board was replaced, shrank or changed at the reader's position (all of it
#   is new to this reader); "none" when there is no usable cursor (first run, unreadable, or older than MAX_AGE_SECONDS).
wr_cursor_get() {
  _g=""; _l=""; _t=""; _s=""
  [ -r "$1" ] || { echo none; return; }                     # a missing cursor is normal on the first arm: say nothing
  read -r _g _l _t _s < "$1" 2>/dev/null || { echo none; return; }
  case "$_l$_t" in ''|*[!0-9]*) echo none; return ;; esac
  [ $(( $(date +%s) - _t )) -le "${3:-86400}" ] || { echo none; return; }
  if [ "$_g" = "$(wr_generation "$2")" ]; then
    _n=$(wc -l < "$2" | tr -d ' ')
    if [ "$_l" -le "$_n" ]; then
      # an old cursor without SUM is accepted once; every cursor written from now on carries it
      if [ -z "$_s" ] || [ "$_l" -eq 0 ] || [ "$_s" = "$(wr_linesum "$2" "$_l")" ]; then echo "$_l"; return; fi
    fi
  fi
  echo 0
}
# wr_cursor_put CURSOR_FILE GENERATION LINE SUM — GENERATION is read before the line count, so a rotation in between is
# noticed at the next read (it can repeat a line, never skip one). SUM is the checksum of line LINE as the reader read it.
# Written to a temp file, then renamed.
wr_cursor_put() {
  printf '%s %s %s %s\n' "$2" "$3" "$(date +%s)" "${4:-0}" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}
