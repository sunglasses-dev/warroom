# I1: negated capture in an if whose body refuses
# expect: pass
F=${1:-}
if ! x=$(cat "$F"); then
  echo "cannot read" >&2
  exit 1
fi
echo "$x"
