# envelope: bin/_lib.sh
# expect: fail ENVELOPE E4
trap 'eval "$1"' EXIT
