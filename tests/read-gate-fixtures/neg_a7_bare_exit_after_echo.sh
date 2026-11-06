# counterexample A7: refused (falls back)
# expect: fail falls back
x=$(cat "$1") || { echo failed >&2; exit; }
echo "$x"
