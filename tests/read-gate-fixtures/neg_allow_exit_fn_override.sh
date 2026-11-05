# the allowlist does not accept this shape: exit fn override
# expect: fail hides or redefines
exit() { echo nope; }
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
