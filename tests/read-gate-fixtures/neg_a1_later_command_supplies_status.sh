# counterexample A1: refused (statement after it)
# expect: fail statement after it
x=$(cat "$1"; true) || exit 1
echo "$x"
