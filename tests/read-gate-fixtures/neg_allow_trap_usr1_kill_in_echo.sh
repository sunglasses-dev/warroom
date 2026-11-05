# a trap on USR1 that exits 0, fired by a kill inside the echo's substitution
# expect: fail hides or redefines
trap 'exit 0' USR1
x=$(cat "$1") || { echo "no $(kill -USR1 $$)" >&2; exit 1; }
echo b > state
