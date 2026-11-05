# the allowlist does not accept this shape: exit bad redir
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || exit 1 > /nonexistent-dir/x
echo "$x" > out
