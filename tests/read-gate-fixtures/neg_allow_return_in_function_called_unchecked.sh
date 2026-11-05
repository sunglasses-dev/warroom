# the refusal is return 1 inside f: it ends f, not the script, so a caller that does not check f carries on
# expect: fail statement after it
f() {
  x=$(cat "$1") || return 1
  echo "$x" > out
}
f "${1:-}"
echo done > state
