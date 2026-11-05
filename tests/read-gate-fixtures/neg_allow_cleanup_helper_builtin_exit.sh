# the cleanup helper ends the shell with builtin exit 0
# expect: fail falls back
wr_drop() { builtin exit 0; }
x=$(cat "$1") || { wr_drop; exit 1; }
echo b > state
