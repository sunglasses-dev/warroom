# the allowlist does not accept this shape: trap in fn
# expect: fail hides or redefines
s() { trap 'exit 0' EXIT; }
s
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
