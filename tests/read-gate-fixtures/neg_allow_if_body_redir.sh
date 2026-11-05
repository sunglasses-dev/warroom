# the allowlist does not accept this shape: if body redir
# expect: fail does not refuse
F=${1:-}
if ! x=$(cat "$F"); then
  exit 1 > /nonexistent-dir/x
fi
echo "$x" > out
