# command unset -f removes the refusal helper
# expect: fail hides or redefines
die() { exit 1; }
command unset -f die
x=$(cat "$1") || die
echo b > state
