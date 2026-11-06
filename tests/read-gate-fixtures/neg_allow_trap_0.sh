# the allowlist does not accept this shape: trap 0
# expect: fail hides or redefines
trap 'exit 0' 0
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
