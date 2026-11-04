# shellcheck shell=bash
# bin/_cursor.sh — read positions in the board that survive a rotation, a truncation and a new day. Sourced after _common.sh.
# A cursor file holds "GENERATION LINE EPOCH". GENERATION is the board's inode plus a checksum of its first line, so a
# replaced file, or one that was emptied and refilled, is noticed even when it is already longer than the old one.
wr_inode() {
  _ino=$(stat -c %i "$1" 2>/dev/null) || _ino=$(stat -f %i "$1" 2>/dev/null) || _ino=0
  case "$_ino" in ''|*[!0-9]*) _ino=0 ;; esac
  echo "$_ino"
}
wr_generation() { echo "$(wr_inode "$1"):$(head -n 1 "$1" 2>/dev/null | cksum | cut -d' ' -f1)"; }
# wr_cursor_get CURSOR_FILE BOARD MAX_AGE_SECONDS
#   prints the line to resume from; 0 when the board was replaced or shrank (all of it is new to this reader);
#   "none" when there is no usable cursor (first run, unreadable, or older than MAX_AGE_SECONDS).
wr_cursor_get() {
  _g=""; _l=""; _t=""
  read -r _g _l _t < "$1" 2>/dev/null || { echo none; return; }
  case "$_l$_t" in ''|*[!0-9]*) echo none; return ;; esac
  [ $(( $(date +%s) - _t )) -le "${3:-86400}" ] || { echo none; return; }
  if [ "$_g" = "$(wr_generation "$2")" ]; then
    _n=$(wc -l < "$2" | tr -d ' ')
    if [ "$_l" -le "$_n" ]; then echo "$_l"; return; fi
  fi
  echo 0
}
# wr_cursor_put CURSOR_FILE GENERATION LINE — GENERATION is read before the line count, so a rotation in between is
# noticed at the next read (it can repeat a line, never skip one). Written to a temp file, then renamed.
wr_cursor_put() {
  printf '%s %s %s\n' "$2" "$3" "$(date +%s)" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}
