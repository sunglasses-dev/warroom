# V: the real board.sh read arm, the last statement of the script
# expect: pass
# allow: V line=6 idx=0
B=${BOARD_FILE:-/dev/null}
case "$1" in
  read) n=${2:-20}; tail -n "$n" "$B" ;;
  *) echo usage >&2 ;;
esac
