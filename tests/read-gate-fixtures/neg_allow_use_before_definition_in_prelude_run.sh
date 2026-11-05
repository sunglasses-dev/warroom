# the first statement that is not a definition ends the prelude: a helper defined after it is not a prelude helper
# expect: fail falls back
x=$(cat /etc/hostname) || die "cannot read"
LIMIT=3
die() { echo "$1" >&2; exit 1; }
echo "$x" > out
