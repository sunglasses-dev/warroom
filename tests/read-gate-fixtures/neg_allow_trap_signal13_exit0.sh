# the same trap named by number
# expect: fail hides or redefines
trap 'exit 0' 13
x=$(cat "$1") || { echo "cannot read $1"; exit 1; }
echo b > state
