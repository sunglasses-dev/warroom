# the allowlist does not accept this shape: exit dollar q
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || { true; exit $?; }
echo "$x" > out
