# the allowlist does not accept this shape: exit bad fd
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || exit 1 2>&7
echo "$x" > out
