# counterexample A2: refused (statement after it)
# expect: fail statement after it
f() {
  x=$(cat "$1")
  echo "reading" >&2
  rc=$?
  if [ "$rc" != 0 ]; then return 1; fi
  echo "$x"
}
