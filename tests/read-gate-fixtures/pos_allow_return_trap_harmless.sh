# a RETURN trap with a harmless action does not hide the refusal (control)
# expect: pass
# min-occurrences: 2
trap 'echo r' RETURN
f() { x=$(cat "$1") || return 1; echo "$x" > out; }
f "${1:-}" || exit 1
