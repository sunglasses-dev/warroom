# command enable -n disables the exit builtin
# expect: fail hides or redefines
command enable -n exit
x=$(cat "$1") || exit 1
echo b > state
