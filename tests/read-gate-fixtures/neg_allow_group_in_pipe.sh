# the allowlist does not accept this shape: group in pipe
# expect: fail another process
F=${1:-}
{ x=$(cat "$F") || exit 1; } | cat
echo "$x" > out
