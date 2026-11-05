# the allowlist does not accept this shape: die nested def
# expect: fail falls back
mk() { die() { :; }; }
die() { exit 1; }
mk
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
