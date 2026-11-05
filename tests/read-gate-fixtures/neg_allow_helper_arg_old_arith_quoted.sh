# the same argument inside double quotes
# expect: fail falls back
die() { echo "$1" >&2; exit 1; }
x=$(cat "$1") || die "$[1/0]"
echo b > state
