# the allowlist does not accept this shape: exit 256
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || exit 256
echo "$x" > out
