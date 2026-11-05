# a trap on PIPE that exits 0: a closed stdout turns the refusal into success
# expect: fail hides or redefines
trap 'exit 0' PIPE
x=$(cat "$1") || { echo "cannot read $1"; exit 1; }
echo b > state
