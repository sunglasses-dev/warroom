# the allowlist does not accept this shape: coprocish
# expect: fail statement after it
F=${1:-}
x=$(cat "$F") || exit 1 |& cat
echo "$x" > out
