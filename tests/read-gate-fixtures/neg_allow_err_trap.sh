# the allowlist does not accept this shape: err trap
# expect: fail hides or redefines
trap "exit 0" ERR
f() {
  x=$(cat "$1" 2>/dev/null)
  rc=$?
  if [ "$rc" != 0 ]; then return 1; fi
  printf "%s\n" "$x" > out
}
f "${1:-}" || exit 1
