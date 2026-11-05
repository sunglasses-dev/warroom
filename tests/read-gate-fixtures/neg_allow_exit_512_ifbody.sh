# the allowlist does not accept this shape: exit 512 ifbody
# expect: fail does not refuse
F=${1:-}
if ! x=$(cat "$F"); then
  exit 512
fi
echo "$x" > out
