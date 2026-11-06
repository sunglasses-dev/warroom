# envelope: bin/_lib.sh
# expect: fail ENVELOPE E4
cmd=${1:-}
"$cmd" --version
