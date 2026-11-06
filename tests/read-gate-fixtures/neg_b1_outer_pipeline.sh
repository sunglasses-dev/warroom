# counterexample B1: refused (pipeline stage)
# expect: fail pipeline stage
x=$(cat "$1" | cksum) || exit 1
echo "$x"
