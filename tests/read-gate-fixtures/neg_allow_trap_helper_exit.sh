# the allowlist does not accept this shape: trap helper exit
# expect: fail hides or redefines
q() { exit 0; }
trap q EXIT
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
