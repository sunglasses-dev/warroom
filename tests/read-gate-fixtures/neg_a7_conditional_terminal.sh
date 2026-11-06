# counterexample A7: refused (falls back)
# expect: fail falls back
x=$(cat "$1") || { [ -n "$2" ] && exit 1; }
echo "$x"
