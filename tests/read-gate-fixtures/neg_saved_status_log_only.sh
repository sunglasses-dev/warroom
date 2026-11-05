# refused: does not return or exit
# expect: fail does not return or exit
f() {
  x=$(cat "$1"); rc=$?
  if [ "$rc" != 0 ]; then echo failed >&2; fi
  echo "$x"
}
