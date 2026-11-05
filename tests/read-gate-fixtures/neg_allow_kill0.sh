# the allowlist does not accept this shape: kill0
# expect: fail statement after it
F=${1:-}
x=$(cat "$F") || kill -0 $$
echo "$x" > out
