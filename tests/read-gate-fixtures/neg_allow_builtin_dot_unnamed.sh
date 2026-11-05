# builtin . sources a file whose name the gate cannot take as a plain word
# expect: fail hides or redefines
builtin . ./lib.sh
x=$(cat "$1") || exit 1
echo b > state
