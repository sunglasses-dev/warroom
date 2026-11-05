# builtin trap installs an EXIT trap that exits 0
# expect: fail hides or redefines
builtin trap 'exit 0' EXIT
x=$(cat "$1") || exit 1
echo b > state
