# refused: falls back
# expect: fail falls back
armfail() { echo "$1" >&2; return 0; }
x=$(cat "$1") || armfail "no"
echo "$x"
