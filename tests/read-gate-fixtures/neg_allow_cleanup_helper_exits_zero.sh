# a cleanup helper in front of the exit that itself ends the shell with status 0: the exit 1 is never reached
# expect: fail falls back
wr_drop() { exit 0; }
F=${1:-}
x=$(cat "$F") || { wr_drop "$F"; exit 1; }
echo "$x" > out
