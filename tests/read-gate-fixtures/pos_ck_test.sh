# CK: a positive existence test whose false branch refuses
# expect: pass
F=${1:-}
[ -e "$F" ] || { echo "missing or unreadable: $F" >&2; exit 1; }
