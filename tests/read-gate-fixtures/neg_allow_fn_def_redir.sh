# the allowlist does not accept this shape: fn def redir
# expect: fail falls back
die() { echo "$1" >&2; exit 1; } > /nonexistent-dir/x
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
