# the allowlist does not accept this shape: def after in fn body
# expect: fail falls back
die() { exit 1; }
g() { die() { :; }; }
g
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
