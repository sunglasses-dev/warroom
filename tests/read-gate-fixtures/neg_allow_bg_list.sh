# the allowlist does not accept this shape: bg list
# expect: fail another process
F=${1:-}
x=$(cat "$F") || exit 1 &
echo "$x" > out
