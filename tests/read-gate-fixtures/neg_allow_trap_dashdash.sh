# the allowlist does not accept this shape: trap dashdash
# expect: fail hides or redefines
trap -- 'exit 0' EXIT
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
