# a cleanup helper that only closes a descriptor of 3 or up cannot leave the shell, so it may stand in front of the exit
# expect: pass
wr_unlock() { if [ -n "${1:-}" ]; then exec 8>&-; fi; }
F=${1:-}
x=$(cat "$F") || { wr_unlock "$F"; echo "cannot read" >&2; exit 3; }
echo "$x" > out
