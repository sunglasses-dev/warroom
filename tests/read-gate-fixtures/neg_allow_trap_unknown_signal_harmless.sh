# a trap on a signal name the shell does not know is never installed, whatever its action says
# expect: fail hides or redefines
trap 'echo cleanup' SIGFOO
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
