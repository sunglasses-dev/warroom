# envelope: bin/_lib.sh
# expect: fail ENVELOPE E3
exec cat "$1" 3>/dev/null
