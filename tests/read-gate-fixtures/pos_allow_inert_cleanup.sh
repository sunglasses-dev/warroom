# echo, printf, rm and a cleanup helper that cannot exit may stand in front of the exit
# expect: pass
wr_drop() { rm -f "$1"; }
F=${1:-}
T=${2:-}
x=$(cat "$F") || { wr_drop "$T"; echo "cannot read" >&2; printf '%s\n' "$F" >&2; exit 3; }
echo "$x" > out
