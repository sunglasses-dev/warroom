# the allowlist does not accept this shape: set e off ifbody
# expect: fail does not refuse
F=${1:-}
if ! x=$(cat "$F"); then
  echo "cannot read" >&2
  exit 1 &
fi
echo "$x" > out
