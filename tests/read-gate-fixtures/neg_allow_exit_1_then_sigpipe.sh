# the allowlist does not accept this shape: exit 1 then sigpipe
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || { echo "cannot read" >&2; exit 01; }
echo "$x" > out
