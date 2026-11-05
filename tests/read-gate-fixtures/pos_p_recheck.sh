# P: a metadata test with a fail-closed recheck of the same operand
# expect: pass
# min-occurrences: 2
# allow: P line=6 idx=0
mk() {
  if [ -e "$1" ]; then echo "$1 exists" >&2; return 1; fi
  : > "$1" || return 1
  [ -e "$1" ] || { echo "$1 missing after create" >&2; return 1; }
}
