# the allowlist does not accept this shape: amp redirect
# expect: fail another process
F=${1:-}
x=$(cat "$F") || exit 1 &>/dev/null
echo "$x" > out
