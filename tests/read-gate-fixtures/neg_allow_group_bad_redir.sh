# the allowlist does not accept this shape: group bad redir
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || { echo e; exit 1; } > /nonexistent-dir/x
echo "$x" > out
