# H: the help text is read without "--", so a script run as "-dir/name" is read by GNU sed as an option
# expect: fail H pipeline is not
# allow: H line=5 idx=0
# allow: H line=5 idx=1
case "${1:-}" in -h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
echo run
