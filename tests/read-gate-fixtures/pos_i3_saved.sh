# I3: saved status tested next, failure branch returns
# expect: pass
f() {
  x=$(cat "$1" 2>/dev/null)
  rc=$?
  if [ "$rc" != 0 ]; then echo "cannot read" >&2; return 1; fi
  echo "$x"
}
