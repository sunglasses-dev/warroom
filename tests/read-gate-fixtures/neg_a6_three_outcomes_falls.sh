# counterexample A6: refused (errno-aware helper)
# expect: fail errno-aware helper
f() {
  x=$(cat "$1" 2>/dev/null); rc=$?
  case "$rc" in
    0) echo "$x" ;;
    3) echo absent ;;
    1) echo "error" ;;
    *) return 1 ;;
  esac
}
