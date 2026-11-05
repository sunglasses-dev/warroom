# the allowlist does not accept this shape: kill term
# expect: fail statement after it
F=${1:-}
x=$(cat "$F") || kill $$
echo "$x" > out
