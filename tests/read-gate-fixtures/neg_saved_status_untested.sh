# refused: does not test it
# expect: fail not tested by an if or case
f() {
  x=$(cat "$1"); rc=$?
  echo "$x"
}
