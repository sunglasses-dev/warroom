# a prelude: literals, pipefail, a helper whose body is a rule-1 list; calls with plain arguments refuse
# expect: pass
set -o pipefail
trap '' PIPE
LIMIT=3
die() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || die "cannot read $F"
echo "$x" > out
