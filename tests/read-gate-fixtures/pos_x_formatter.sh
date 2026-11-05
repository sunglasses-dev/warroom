# X: terminal error formatter that repeats the failed open to print its error
# expect: pass
# allow: X line=5 idx=0
f() {
  echo "cannot open: $( { : >> "$1.flock"; } 2>&1 | sed 's/.*: //' | head -1)" >&2; return 1
}
