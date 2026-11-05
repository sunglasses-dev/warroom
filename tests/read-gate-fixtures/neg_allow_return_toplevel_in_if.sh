# the allowlist does not accept this shape: return toplevel in if
# expect: fail does not refuse
F=${1:-}
if ! x=$(cat "$F"); then
  return 1
fi
echo "$x" > out
