# the allowlist does not accept this shape: exit arith err
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || exit $((1/0))
echo "$x" > out
