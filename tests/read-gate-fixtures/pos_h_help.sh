# H: help text read from the script itself
# expect: pass
# min-occurrences: 2
# allow: H line=6 idx=0
# allow: H line=6 idx=1
case "${1:-}" in -h|--help) sed -n -- '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
echo run
