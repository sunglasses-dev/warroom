# envelope: bin/_lib.sh
# expect: fail ENVELOPE E4
say() { echo hi; }
trap 'exec 2>"$1"; say' EXIT
