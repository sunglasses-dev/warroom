# tests/smoke-lib.sh — definitions and setup shared by every part of tests/smoke.sh.
# Sourced by smoke.sh after its preamble (ROOT, T, B, ok/bad/sec exist by then); never run on its own.
# Moved verbatim from smoke.sh, in the original order: functions the sections call, plus the setup lines they need.
# shellcheck shell=bash
# shellcheck disable=SC2034  # PS_OK and the marker below are read by smoke.sh, the file that sources this one
SMOKE_LIB_SOURCED=1
seat_round() { # seat_round BINDIR WARROOMDIR TAG: 0 = settled with exactly one live arm, 1 = not (PA_WHY says what was seen)
  local _b=$1 _w=$2 _t=$3 _p1 _p2 _live _rows _who _n=0 _holds=0 _ok=1
  rm -f "$_w/seats.tsv" "$_w"/.cursor-*
  WARROOM_DIR="$_w" "$_b/waiter.sh" BOSS "sid-$_t-a" >/dev/null 2>&1 & _p1=$!
  WARROOM_DIR="$_w" "$_b/waiter.sh" BOSS "sid-$_t-b" >/dev/null 2>&1 & _p2=$!
  while [ $_n -lt 75 ]; do   # 75 looks of 0.2 s = 15 s
    _live=0; kill -0 $_p1 2>/dev/null && _live=$((_live+1)); kill -0 $_p2 2>/dev/null && _live=$((_live+1))
    _rows=$(awk -F'\t' '$2=="BOSS"' "$_w/seats.tsv" 2>/dev/null | wc -l | tr -d ' ')
    _who=$(awk -F'\t' '$2=="BOSS" {print $1}' "$_w/seats.tsv" 2>/dev/null)
    if [ $_live = 1 ] && [ "$_rows" = 1 ] && { { kill -0 $_p1 2>/dev/null && [ "$_who" = "sid-$_t-a" ]; } || { kill -0 $_p2 2>/dev/null && [ "$_who" = "sid-$_t-b" ]; }; }; then
      _holds=$((_holds+1)); [ $_holds -ge 3 ] && { _ok=0; break; }   # the settling look and two more
      sleep 0.5; _n=$((_n+3))
    else _holds=0; sleep 0.2; _n=$((_n+1)); fi
  done
  PA_WHY="not one live arm with one matching registry row after 15 s: live $_live, rows $_rows, row names '$_who'"
  kill $_p1 $_p2 2>/dev/null; wait $_p1 $_p2 2>/dev/null
  return $_ok
}
fx_seatrace() { PA_IN=""; pa_setup; pa_pass WARROOM_DIR="$PAW/sr" "$PB/board.sh" path || return 1; seat_round "$PB" "$PAW/sr" fx; }
LD="$T/lock"; mkdir -p "$LD"; C="$B/_common.sh"
# TRY FILE: an independent fresh process tries FILE's lock for 1 s and prints 0 (taken) or 1 (held elsewhere)
printf '%s\n' 'WARROOM_LOCK_WAIT=1; . "$WR_C"; wr_lock "$1" >/dev/null 2>&1; echo $?' > "$LD/try.sh"
export WR_C="$C" TRY="$LD/try.sh"
try() { bash "$TRY" "$1"; }
lk() { s=$1; shift; WARROOM_LOCK_WAIT=1 bash -c ". \"\$WR_C\"; $s" _ "$@" 2>&1; }   # run a snippet in a fresh shell
hold() { # hold FILE: a fresh process takes FILE's lock and keeps it (its sleeps run through wr_run); HP = its pid
  WARROOM_LOCK_WAIT=5 bash -c '. "$WR_C"; wr_lock "$1" || exit 1; : > "$1.held"; while :; do wr_run sleep 1; done' _ "$1" >/dev/null 2>&1 & HP=$!
  for _ in $(seq 1 50); do [ -e "$1.held" ] && return 0; sleep 0.1; done; return 1; }
unhold() { kill -9 "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; rm -f "$1.held"; }
ino() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
lst() { ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; }
PB="$B"; PHK="$ROOT/hooks"; PA_IN='{"session_id": "sid-pa"}'; PA_WHY=""; PA_SKIP=""; PA_NOTE=""
pa_setup() { PAW=$(cd -P "$(mktemp -d "$T/paw.XXXXXX")" && pwd -P); PAH="$PAW/h"; PAC="$PAW/cfg"; mkdir -p "$PAH" "$PAC" "$PAW/cwd"; }
pa_snap() { find "$PAW" -print 2>/dev/null | LC_ALL=C sort; }
pa_mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
pa_run() { ( cd "${PA_CWD:-$PAW/cwd}" && env HOME="$PAH" CLAUDE_CONFIG_DIR="$PAC" PYTHONDONTWRITEBYTECODE=1 WARROOM_ENV="$PAW/none.env" SEATS="BOSS W1" WARROOM_POLL=1 WARROOM_MIN_GAP=0 "$@" ); }
pa_exec() { PA_OUT=$(printf '%s' "$PA_IN" | pa_run "$@" 2>&1); PA_RC=$?; }
pa_pass() { pa_exec "$@"; [ "$PA_RC" = 0 ] || { PA_WHY="rc $PA_RC (want 0): $* -> $(printf '%s' "$PA_OUT" | head -c 160)"; return 1; }; }
pa_want() {
  _pat=$1; _wrc=$2; shift 2
  pa_snap > "$PAW.b"; pa_exec "$@"; pa_snap > "$PAW.a"
  [ "$PA_RC" = "$_wrc" ] || { PA_WHY="rc $PA_RC (want $_wrc): $* -> $(printf '%s' "$PA_OUT" | head -c 160)"; return 1; }
  printf '%s\n' "$PA_OUT" | grep -Eq -- "$_pat" || { PA_WHY="no '$_pat' in: $(printf '%s' "$PA_OUT" | head -c 160) ($*)"; return 1; }
  cmp -s "$PAW.b" "$PAW.a" || { PA_WHY="created: $(diff "$PAW.b" "$PAW.a" | grep '^[<>]' | head -3 | tr '\n' ' ') ($*)"; return 1; }
  return 0
}
pa_cfgbytes() { printf 'SEATS=BOSS W1\n' > "$1"; }
fx_r1() { # the config folder, spelled four lexical ways and through a symlink, is refused
  pa_setup; ln -s "$PAC" "$PAW/lnk-cfg"
  for w in "$PAC" "$PAC/" "$PAC/x/.." "$PAC/." "$PAW/lnk-cfg" "$PAW/lnk-cfg/"; do
    pa_want 'config folder|component' 2 WARROOM_DIR="$w" "$PB/board.sh" path || return 1
  done
}
fx_r2() { # an absent nested run folder is made only after the checks; the board is exactly under it (physical spelling)
  pa_setup
  pa_pass WARROOM_DIR="$PAW/fresh/a/b" "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/fresh/a/b/board.md" ] && [ -f "$PAW/fresh/a/b/board.md" ] || { PA_WHY="board path '$PA_OUT'"; return 1; }
  mkdir "$PAW/real"; ln -s "$PAW/real" "$PAW/lnk"
  pa_pass WARROOM_DIR="$PAW/lnk/f2/g" "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/lnk/f2/g/board.md" ] && [ -f "$PAW/real/f2/g/board.md" ] || { PA_WHY="symlinked spelling: '$PA_OUT'"; return 1; }
}
fx_r3() { # a refused board leaves a fresh run folder AND the board's parents uncreated (checks come before the bootstrap)
  pa_setup
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/w3" BOARD="$PAW/fresh2/x/settings.json" "$PB/board.sh" path || return 1
  [ ! -e "$PAW/w3" ] && [ ! -e "$PAW/fresh2" ] || { PA_WHY="w3 or fresh2 was created"; return 1; }
}
fx_r4() { # a parent that cannot be searched is refused, nothing created (skipped as root)
  if [ "$(id -u)" = 0 ]; then PA_SKIP="running as root: mode 000 does not block root"; return 0; fi
  pa_setup; mkdir "$PAW/r4"; chmod 000 "$PAW/r4"
  if ( cd "$PAW/r4" ) 2>/dev/null; then chmod 755 "$PAW/r4"; PA_SKIP="the folder stayed accessible (an ACL or a privileged user)"; return 0; fi
  pa_want 'cannot be resolved' 2 WARROOM_DIR="$PAW/r4/w" "$PB/board.sh" path; _r=$?; chmod 755 "$PAW/r4"; return $_r
}
fx_r5() { # a board with a trailing /, an existing folder, a folder symlink, or a folder above the run folder
  pa_setup; mkdir -p "$PAW/r5/d" "$PAW/r5/t"; ln -s "$PAW/r5/d" "$PAW/r5/dl"
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD="$PAW/r5/b/" "$PB/board.sh" path || return 1
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD=d "$PB/board.sh" path || return 1
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD=dl "$PB/board.sh" path || return 1
  pa_want 'above the run folder' 2 WARROOM_DIR="$PAW/a/w" BOARD="$PAW/a" "$PB/board.sh" path || return 1
  [ ! -e "$PAW/a" ] || { PA_WHY="$PAW/a was created"; return 1; }
}
fx_r6() {
  pa_setup; mkdir -p "$PAW/p1" "$PAW/p2"
  pa_want 'WARROOM_DIR must be an absolute path' 2 WARROOM_DIR=run "$PB/board.sh" path || return 1
  pa_want 'WARROOM_ENV must be an absolute path' 2 WARROOM_ENV=rel.env WARROOM_DIR="$PAW/r6" "$PB/board.sh" path || return 1
  for b in ./board.md ../x a/./b; do
    pa_want 'BOARD must not contain \. or \.\. components; write board\.md' 2 WARROOM_DIR="$PAW/r6" BOARD="$b" "$PB/board.sh" path || return 1
  done
  PA_CWD="$PAW/p1" pa_pass WARROOM_DIR="$PAW/r6" BOARD=board.md "$PB/board.sh" path || return 1; _a=$PA_OUT
  PA_CWD="$PAW/p2" pa_pass WARROOM_DIR="$PAW/r6" BOARD=board.md "$PB/board.sh" path || return 1
  [ "$_a" = "$PA_OUT" ] && [ "$_a" = "$PAW/r6/board.md" ] && [ ! -e "$PAW/p1/board.md" ] && [ ! -e "$PAW/p2/board.md" ] || { PA_WHY="board path from p1 '$_a', p2 '$PA_OUT'"; return 1; }
}
fx_r7a() { # W cannot be reassigned by a script that sourced _common.sh
  pa_setup; pa_exec WARROOM_DIR="$PAW/r7" bash -c '. "$1"; W=/elsewhere; echo "w=$W"' _ "$PB/_common.sh"
  case "$PA_OUT" in *"W: readonly variable"*) case "$PA_OUT" in *elsewhere*) ;; *) return 0 ;; esac ;; esac; PA_WHY="W was assignable: $PA_OUT"; return 1
}
fx_r7b() { # BOARD_FILE cannot be reassigned either
  pa_setup; pa_exec WARROOM_DIR="$PAW/r7" bash -c '. "$1"; BOARD_FILE=/elsewhere; echo "b=$BOARD_FILE"' _ "$PB/_common.sh"
  case "$PA_OUT" in *"BOARD_FILE: readonly variable"*) case "$PA_OUT" in *elsewhere*) ;; *) return 0 ;; esac ;; esac; PA_WHY="BOARD_FILE was assignable: $PA_OUT"; return 1
}
fx_r7c() { # a child started with BOARD=settings.json re-validates and is refused
  pa_setup; pa_pass WARROOM_DIR="$PAW/r7" "$PB/board.sh" path || return 1
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/r7" bash -c 'BOARD=settings.json "$1" path' _ "$PB/board.sh"
}
fx_r8() { # a HOME with a trailing / (or HOME=/) is the same HOME: the default config path and ~/ values add no second /
  pa_setup
  pa_pass HOME="$PAH/" WARROOM_DIR="$PAW/r8a" bash -c 'unset WARROOM_ENV; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/r8a/board.md" ] || { PA_WHY="HOME with a trailing /: board '$PA_OUT'"; return 1; }
  pa_pass HOME=/ WARROOM_DIR="$PAW/r8b" bash -c 'unset WARROOM_ENV; exec "$@"' _ "$PB/board.sh" path || return 1
  printf 'WARROOM_DIR=~/sub\n' > "$PAW/r8.env"
  pa_pass HOME="$PAH/" WARROOM_ENV="$PAW/r8.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAH/sub/board.md" ] || { PA_WHY="a home-relative value under HOME with a trailing /: board '$PA_OUT'"; return 1; }
  # a bare ~ stays HOME as written (line 23 of _config.sh): HOME with a trailing / still gives HOME/board.md, HOME=/ is refused
  printf 'WARROOM_DIR=~\n' > "$PAW/r8c.env"
  pa_pass HOME="$PAH/" WARROOM_ENV="$PAW/r8c.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAH/board.md" ] || { PA_WHY="a bare ~ with HOME ending in /: board '$PA_OUT'"; return 1; }
  pa_want 'names no folder or file' 2 HOME=/ WARROOM_ENV="$PAW/r8c.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
}
fx_n1() {
  pa_setup; mkdir -p "$PAW/n1b"; printf 'keep' > "$PAW/n1b/settings.json"; _k=$(cksum < "$PAW/n1b/settings.json")
  _sl=settings.l; _sl="${_sl}ocal.json"
  for n in settings.json Settings.JSON "$_sl" MANAGED-settings.json .Claude.json; do
    pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1a" BOARD="$n" "$PB/board.sh" post BOSS hello || return 1
  done
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1b" BOARD=settings.json "$PB/board.sh" post BOSS hello || return 1
  [ "$(cksum < "$PAW/n1b/settings.json")" = "$_k" ] || { PA_WHY="an existing settings.json changed"; return 1; }
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1c/SETTINGS.json" "$PB/board.sh" path || return 1
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1a" BOARD=Settings.JSON "$PB/waiter.sh" W1 sid-n1 || return 1
  for h in waiter-check board-tail board-guard; do
    pa_want 'settings file' 1 WARROOM_DIR="$PAW/n1a" BOARD=settings.json "$PHK/$h.sh" || return 1
  done
  pa_want 'cannot locate the Claude Code config folder' 2 CLAUDE_CONFIG_DIR=cfg WARROOM_DIR="$PAW/n1d" "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" bash -c 'unset HOME CLAUDE_CONFIG_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" bash -c 'unset CLAUDE_CONFIG_DIR; exec env HOME=rel "$@"' _ "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" HOME= bash -c 'unset CLAUDE_CONFIG_DIR; exec "$@"' _ "$PB/board.sh" path
}
fx_n2() {
  pa_setup; W="$PAW/n2/w"
  for n in seats.tsv pids.tsv .cursor-W1 .lastwake-W1 .anchor-W1 .guard-W1 .poll-W1.123 .snap-W1.123 .wrtmp.abcd1234 x.flock b.tmp.123 b.chunk.123 .LASTWAKE-W1 SEATS.TSV \
           seats.tsv/board.md sub/.anchor-W1/b.md .wrtmp.q/b.md "$W/.cursor-W1/b.md"; do
    pa_want 'name this tool writes|ends in \.flock' 2 WARROOM_DIR="$W" BOARD="$n" "$PB/board.sh" path || return 1
  done
  mkdir -p "$PAW/n2e"; printf 'x' > "$PAW/n2e/seats.tsv"; _k=$(cksum < "$PAW/n2e/seats.tsv")
  pa_want 'name this tool writes' 2 WARROOM_DIR="$PAW/n2e" BOARD=seats.tsv "$PB/board.sh" path || return 1
  [ "$(cksum < "$PAW/n2e/seats.tsv")" = "$_k" ] || { PA_WHY="an existing seats.tsv changed"; return 1; }
  for n in board.tmp.md x.tmp.d/b.md sub/board.md; do   # not reserved: board.tmp.md, a folder named x.tmp.d, a plain subfolder
    pa_pass WARROOM_DIR="$PAW/n2c" BOARD="$n" "$PB/board.sh" path || return 1; rm -rf "${PAW:?}/n2c"
  done
}
fx_n3() {
  pa_setup; W="$PAW/n3/w"; mkdir -p "$W"; pa_cfgbytes "$PAW/n3/c.env"; _k=$(cksum < "$PAW/n3/c.env")
  pa_want 'config file' 2 WARROOM_ENV="$PAW/n3/c.env" WARROOM_DIR="$W" BOARD="$PAW/n3/c.env" "$PB/board.sh" path || return 1
  [ "$(cksum < "$PAW/n3/c.env")" = "$_k" ] || { PA_WHY="the config file changed"; return 1; }
  printf 'row\n' > "$W/pids.tsv"; ln "$W/pids.tsv" "$W/b.md"
  pa_want 'same file as a state entry' 2 WARROOM_DIR="$W" BOARD=b.md "$PB/board.sh" path || return 1
  ln -s "$W" "$PAW/link-to-W"
  pa_want 'name this tool writes' 2 WARROOM_DIR="$W" BOARD="$PAW/link-to-W/seats.tsv" "$PB/board.sh" path
}
fx_n4() { # controls: a plain subfolder board; an external board (its lock file appears beside it, as documented)
  pa_setup
  pa_pass WARROOM_DIR="$PAW/n4" BOARD=sub/board.md "$PB/board.sh" path || return 1
  pa_pass WARROOM_DIR="$PAW/n4" BOARD="$PAW/ext/board.md" "$PB/board.sh" post BOSS hi || return 1
  [ -f "$PAW/ext/board.md.flock" ] && grep -q hi "$PAW/ext/board.md" || { PA_WHY="no ext/board.md.flock after the post"; return 1; }
}
fx_n5() { # a fullwidth lookalike of settings.json is not folded: accepted (a stated limit); the filesystem's own answer is recorded
  pa_setup; mkdir -p "$PAW/n5"; : > "$PAW/n5/settings.json"; _fw=$(printf '\357\275\223ettings.json')
  pa_pass WARROOM_DIR="$PAW/n5" BOARD="$_fw" "$PB/board.sh" path || return 1
  [ -f "$PAW/n5/$_fw" ] || { PA_WHY="lookalike board not created"; return 1; }
  if [ "$PAW/n5/$_fw" -ef "$PAW/n5/settings.json" ]; then PA_NOTE="observed: the filesystem treats the lookalike as the same file"; else PA_NOTE="observed: the filesystem makes a distinct entry for the lookalike"; fi
}
fx_n6a() { # absent and existing, at each derived slot of the run folder
  pa_setup; W="$PAW/n6"
  for slot in .anchor-W1 seats.tsv pids.tsv .guard-W1 .lastwake-W1 .cursor-W1 .anchor-W9 board.md.flock .wrtmp.q1; do
    pa_want 'name this tool writes|lock file|ends in \.flock' 2 WARROOM_ENV="$W/$slot" WARROOM_DIR="$W" "$PB/board.sh" path || return 1   # absent
    mkdir -p "$W"; pa_cfgbytes "$W/$slot"; _k=$(cksum < "$W/$slot"); _m=$(pa_mt "$W/$slot")
    pa_want 'name this tool writes|lock file|ends in \.flock' 2 WARROOM_ENV="$W/$slot" WARROOM_DIR="$W" "$PB/board.sh" path || return 1   # existing
    [ "$(cksum < "$W/$slot")" = "$_k" ] && [ "$(pa_mt "$W/$slot")" = "$_m" ] || { PA_WHY="config at $slot changed"; return 1; }
    rm -rf "${W:?}"
  done
}
fx_n6b() { # under a nested reserved component, and the control at a plain name
  pa_setup; W="$PAW/n6"
  pa_want 'name this tool writes' 2 WARROOM_ENV="$W/.cursor-W1/sub/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  mkdir -p "$W/.cursor-W1/sub"; pa_cfgbytes "$W/.cursor-W1/sub/warroom.env"
  pa_want 'name this tool writes' 2 WARROOM_ENV="$W/.cursor-W1/sub/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  rm -rf "${W:?}"; mkdir -p "$W"; pa_cfgbytes "$W/warroom.env"
  pa_pass WARROOM_ENV="$W/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path
}
fx_n6c() { # the same file under another name: a hard link to a state entry or to the board's lock file; a dangling link to a slot
  pa_setup; W="$PAW/n6"; mkdir -p "$W"
  pa_cfgbytes "$W/.anchor-W1"; ln "$W/.anchor-W1" "$PAW/hl-anchor.env"
  pa_want 'same file as a state entry|name this tool writes' 2 WARROOM_ENV="$PAW/hl-anchor.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  pa_cfgbytes "$W/board.md.flock"; ln "$W/board.md.flock" "$PAW/hl-flock.env"
  pa_want 'lock file' 2 WARROOM_ENV="$PAW/hl-flock.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  rm -f "${W:?}/.anchor-W1"; ln -s "$W/.anchor-W1" "$PAW/dangling.env"
  pa_want 'leads nowhere|name this tool writes' 2 WARROOM_ENV="$PAW/dangling.env" WARROOM_DIR="$W" "$PB/board.sh" path
}
fx_n6d() { # a config path whose links loop is refused, and so is a link that leads nowhere
  pa_setup; ln -s "$PAW/loop2" "$PAW/loop1"; ln -s "$PAW/loop1" "$PAW/loop2"
  pa_want 'config path loops' 2 WARROOM_ENV="$PAW/loop1" WARROOM_DIR="$PAW/n6d" "$PB/board.sh" path || return 1
  ln -s "$PAW/nowhere.env" "$PAW/dangling.env"
  pa_want 'link that leads nowhere' 2 WARROOM_ENV="$PAW/dangling.env" WARROOM_DIR="$PAW/n6d" "$PB/board.sh" path
}
fx_s1() {
  pa_setup; W="$PAW/s1"
  pa_exec WARROOM_DIR="$W" "$PB/board.sh" tail ../x
  [ "$PA_RC" = 2 ] && [ "$(find "$W" -print | LC_ALL=C sort | tr '\n' ' ')" = "$W $W/board.md " ] || { PA_WHY="fresh run: rc $PA_RC, new entries: $(find "$W" -print | LC_ALL=C sort | tr '\n' ' ')"; return 1; }
  for a in ../x W1/x "" w1 ZZ NONE; do
    pa_want 'unknown seat|usage' 2 WARROOM_DIR="$W" "$PB/board.sh" tail "$a" || return 1
  done
  pa_want 'usage' 2 WARROOM_DIR="$W" "$PB/board.sh" tail || return 1
  pa_want 'unknown seat' 2 WARROOM_DIR="$W" "$PB/waiter.sh" ../x sid-s1 || return 1
}
fx_s2() { # a registry row is data: a seat outside SEATS is not trusted by the read hooks
  pa_setup; W="$PAW/s2"; pa_pass WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  printf '[00:00 · BOSS] hello\n' >> "$W/board.md"; printf 'sid-pa\t../x\t99999\tx\tstart\n' > "$W/seats.tsv"
  pa_want 'unknown seat in registry' 0 WARROOM_DIR="$W" "$PHK/waiter-check.sh" || return 1
  pa_want '^$' 0 WARROOM_DIR="$W" "$PHK/board-tail.sh" || return 1
  printf 'sid-pa\tW1\t99999\tx\tstart\n' > "$W/seats.tsv"
  pa_pass WARROOM_DIR="$W" "$PHK/board-tail.sh" || return 1
  case "$PA_OUT" in *"[BOARD]"*) return 0 ;; esac; PA_WHY="control (registry seat W1) printed '$PA_OUT'"; return 1
}
fx_p1() {
  pa_setup; mkdir -p "$PAW/nopy" "$PAW/brokenpy"
  for t in dirname bash; do ln -s "$(command -v $t)" "$PAW/nopy/$t"; done
  for t in dirname bash; do ln -s "$(command -v $t)" "$PAW/brokenpy/$t"; done
  printf '#!/bin/sh\nexit 1\n' > "$PAW/brokenpy/python3"; chmod +x "$PAW/brokenpy/python3"
  for d in nopy brokenpy; do
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/board.sh" path || return 1
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/waiter.sh" W1 sid-p1 || return 1
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/pids.sh" check || return 1
    for h in waiter-check board-tail board-guard; do
      pa_want 'python3 is required' 1 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PHK/$h.sh" || return 1
    done
  done
}
fx_p2() { # python3 passes the startup check and fails only the hook's JSON parse: exit 1 with a message, never a silent 0
  pa_setup; mkdir -p "$PAW/shim"; _py=$(command -v python3); pa_pass WARROOM_DIR="$PAW/p2" "$PB/board.sh" path || return 1
  printf '#!/bin/sh\ncase "$*" in *json*) echo "shim: json failed" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$_py" > "$PAW/shim/python3"; chmod +x "$PAW/shim/python3"
  for h in waiter-check board-tail; do
    pa_want 'could not read the hook input' 1 PATH="$PAW/shim:$PATH" WARROOM_DIR="$PAW/p2" "$PHK/$h.sh" || return 1
  done
  PA_IN='not json'; for h in waiter-check board-tail; do pa_want 'could not read the hook input' 1 WARROOM_DIR="$PAW/p2" "$PHK/$h.sh" || { PA_IN='{"session_id": "sid-pa"}'; return 1; }; done
  PA_IN='{"session_id": "sid-pa"}'
}
fx_p3() { # a json.py planted in the folder the hook runs from is never imported: the hooks start python3 isolated
  pa_setup; mkdir -p "$PAW/plant"; printf 'open("PWNED", "w").write("ran")\ndef load(f):\n    return {"session_id": "sid-pa"}\n' > "$PAW/plant/json.py"
  PA_CWD="$PAW/plant"
  for h in waiter-check board-tail; do
    pa_pass WARROOM_DIR="$PAW/p3" "$PHK/$h.sh" || { PA_CWD=""; return 1; }
    [ ! -e "$PAW/plant/PWNED" ] || { PA_WHY="$h imported the json.py from its working folder"; PA_CWD=""; return 1; }
  done
  PA_CWD=""
}
fx_h1() { # a bad warroom.env: every hook exits 1, never 2, and the message names the line
  pa_setup; printf 'SEATS=$(touch x)\n' > "$PAW/bad.env"
  for h in waiter-check board-tail board-guard; do
    pa_want 'warroom\.env line 1' 1 WARROOM_ENV="$PAW/bad.env" WARROOM_DIR="$PAW/h1" "$PHK/$h.sh" || return 1
  done
}
pa_run_fx() { # pa_run_fx FIXTURE "what it shows": ok, a printed skip, or FAIL with the assert that fired
  PA_WHY=""; PA_SKIP=""; PA_NOTE=""
  if "$1"; then if [ -n "$PA_SKIP" ]; then echo "skip $2 ($PA_SKIP)"; else ok "$2${PA_NOTE:+ [$PA_NOTE]}"; fi; else bad "$2: $PA_WHY"; fi
}
PS_OK=1; [ -n "$(ps -o lstart= -p $$ 2>/dev/null)" ] || PS_OK=0   # sections 51-55 and their mutants arm waiters, which need ps to read a start time; without it they are skipped, printed as skips
l51_base() { rm -rf "$L51/w" "$L51/tgt"; : > "$L51/o"; : > "$L51/e"; mkdir -p "$L51/w" "$L51/tgt";   # o and e are emptied by us: a background job truncates its own redirect late, and wait_text must not see the last run's 'armed'
  printf '[00:00 · BOSS] one\n' > "$L51/w/board.md"; }
l51_clean() { [ ! -e "$L51/tgt/$1" ] && [ -L "$L51/w/$1" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ]; }
fault_set() { rm -f "$FAULT55/$1" "$FAULT55/$1.cnt"; printf '%s\n' "$2" > "$FAULT55/$1"; }
fault_clear() { rm -f "$FAULT55"/*; }
l52_base() { rm -rf "$L51/w"; : > "$L51/o"; : > "$L51/e"; mkdir -p "$L51/w"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] two\n' > "$L51/w/board.md"; printf 'other-sid\tBOSS\t1\t00:00\n' > "$L51/w/seats.tsv"; }
l52_dir() { ls -A "$L51/w" | tr '\n' ' '; }
l55_run() { # name mode desc: mode = filter | gen | prefix | snap, the fault is set before the wake line is posted
  l52_base; rm -f "$L51/w/seats.tsv"; WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-$1 > "$L51/o" 2>"$L51/e" & WP=$!; wait_text "$L51/e" '^armed ' 20; c0=$(cksum < "$L51/w/.cursor-W1")
  case $2 in
    filter) fault_set awk filter ;;
    gen)    fault_set cksum "$(head -n 1 "$L51/w/board.md" | wc -c | tr -d ' ')" ;;
    prefix) fault_set cksum "$(wc -c < "$L51/w/board.md" | tr -d ' ')" ;;
    snap)   fault_set cksum "$(( $(wc -c < "$L51/w/board.md") + $(printf '[00:00 · BOSS] @W1 ACTION: %s line\n' "$1" | wc -c) ))" ;;
  esac
  WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: $1 line" >/dev/null; sleep 3
  alive=0; kill -0 $WP 2>/dev/null && alive=1; mid=$(cksum < "$L51/w/.cursor-W1"); said=$(grep -c "nothing consumed" "$L51/e"); fault_clear
  wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null
  if [ $alive = 1 ] && [ "$mid" = "$c0" ] && [ "$said" -ge 1 ] && grep -q "$1 line" "$L51/o"; then ok "consume: $3 consumes nothing (waiter stays up, position kept, message) and the line comes on the next good poll"; else bad "consume $1: alive $alive said $said same-pos $([ "$mid" = "$c0" ] && echo y || echo n), out '$(cat "$L51/o")', err '$(cat "$L51/e")'"; fi
}
SHRO="$T/shimro"; mkdir -p "$SHRO"; FRO="$T/faultro"; _rmk=$(command -v mktemp)
cat > "$SHRO/mktemp" <<SHIM
#!/bin/sh
f="$FRO"
if [ -f "\$f" ]; then
  k=\$(cat "\$f"); n=\${k%% *}; pat=\${k#* }; [ "\$pat" = "\$k" ] && pat=""
  if [ -n "\$pat" ]; then par=\$(ps -o command= -p \$PPID 2>/dev/null); case "\$par" in *"\$pat"*) ;; *) exec $_rmk "\$@" ;; esac; fi
  c=\$(cat "\$f.cnt" 2>/dev/null || echo 0); c=\$((c+1)); echo "\$c" > "\$f.cnt"
  if [ "\$n" = "\$c" ]; then p=\$($_rmk "\$@") || exit 1; chmod 444 "\$p"; echo "\$c" >> "\$f.hit"; echo "\$p"; exit 0; fi
fi
exec $_rmk "\$@"
SHIM
chmod +x "$SHRO/mktemp"
ro_set() { rm -f "$FRO.cnt" "$FRO.hit"; printf '%s\n' "$1" > "$FRO"; }
ro_clear() { rm -f "$FRO" "$FRO.cnt"; }
ro_hit() { [ -s "$FRO.hit" ]; }
f2_base() { rm -rf "$L51/w"; : > "$L51/o"; : > "$L51/e"; mkdir -p "$L51/w"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] three words here\n' > "$L51/w/board.md"; }
f2_tail() { WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" "$B/board.sh" tail BOSS 2>"$L51/e"; }
