# the unlock helper replaces the shell with command exec
# expect: fail falls back
wr_unlock() { command exec true; }
x=$(cat "$1") || { wr_unlock; exit 1; }
echo b > state
