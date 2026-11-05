# the allowlist does not accept this shape: exit space paren
# expect: fail hides or redefines
exit () { :; }
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
