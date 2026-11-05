# counterexample A9: refused (statement after it)
# expect: fail statement after it
f() {
  _gi=$(cat "$1")
  _gs=$(cat "$2") || return 1
  echo "$_gi$_gs"
}
