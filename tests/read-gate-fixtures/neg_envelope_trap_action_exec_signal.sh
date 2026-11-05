# envelope: bin/_lib.sh
# expect: fail ENVELOPE E4
trap 'exec 2>"$1"' USR1
kill -USR1 $$
