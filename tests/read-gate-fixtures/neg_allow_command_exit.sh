# the allowlist does not accept this shape: command exit
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || command exit 1
echo "$x" > out
