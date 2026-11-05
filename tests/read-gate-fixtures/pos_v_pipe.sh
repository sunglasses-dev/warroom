# V: a view pipeline with pipefail, last statement
# expect: pass
# min-occurrences: 2
# allow: V line=8 idx=0
# allow: V line=8 idx=1
set -o pipefail
B=${BOARD_FILE:-/dev/null}
sed -n "2,9p" "$B" | cut -c1-300
