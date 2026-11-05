# counterexample A7: refused (falls back)
# expect: fail falls back
f() {
  x=$(cat "$1") || { echo failed >&2; return; }
  echo "$x"
}
