# the allowlist does not accept this shape: bg group
# expect: fail another process
F=${1:-}
{ x=$(cat "$F") || exit 1; } &
wait
echo "$x" > out
