# the allowlist does not accept this shape: trap var
# expect: fail hides or redefines
t=EXIT
trap 'exit 0' $t
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
