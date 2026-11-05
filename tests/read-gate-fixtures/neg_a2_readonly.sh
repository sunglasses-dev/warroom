# counterexample A2: refused (declaration builtin)
# expect: fail declaration builtin
readonly X=$(cat "$1") || exit 1
