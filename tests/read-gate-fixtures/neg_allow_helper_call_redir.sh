# the allowlist does not accept this shape: helper call redir
# expect: fail falls back
die() { exit 1; }
F=${1:-}
x=$(cat "$F") || die > /nonexistent-dir/x
echo "$x" > out
