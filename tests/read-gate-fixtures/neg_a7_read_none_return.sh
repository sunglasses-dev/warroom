# counterexample A7: refused (read returns 1)
# expect: fail read returns 1
f() {
  read -r a < "$1" 2>/dev/null || { echo none; return; }
  echo "$a"
}
