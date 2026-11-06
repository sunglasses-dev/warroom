# the allowlist does not accept this shape: toplevel return
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || return 1
echo "$x" > out
