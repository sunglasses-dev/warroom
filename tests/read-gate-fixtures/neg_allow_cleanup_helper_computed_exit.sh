# the cleanup helper runs a computed command that is exit
# expect: fail falls back
E=exit
wr_drop() { $E 0; }
x=$(cat "$1") || { wr_drop; exit 1; }
echo b > state
