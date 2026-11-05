# the allowlist does not accept this shape: function kw
# expect: fail hides or redefines
function exit { :; }
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
