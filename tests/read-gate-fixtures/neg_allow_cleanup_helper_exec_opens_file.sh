# a helper whose exec opens a file can fail and leave the shell, so it does not stand in front of the exit
# expect: fail falls back
wr_unlock() { exec 8>>"$1.lock"; }
F=${1:-}
x=$(cat "$F") || { wr_unlock "$F"; echo "cannot read" >&2; exit 3; }
echo "$x" > out
