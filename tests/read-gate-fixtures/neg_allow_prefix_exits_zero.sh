# an item in front of the terminal that can end the shell with status 0: the terminal is never reached
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || { exit 0; exit 1; }
echo "$x" > out
