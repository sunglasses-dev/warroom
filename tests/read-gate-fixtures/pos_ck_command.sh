# CK: a reader called as cmd || REFUSE
# expect: pass
# min-occurrences: 2
F=${1:-}
head -n 3 "$F" > /dev/null || exit 1
tail -n 3 "$F" > /dev/null || { echo "cannot read" >&2; exit 1; }
