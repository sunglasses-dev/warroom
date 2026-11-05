# counterexample A2: refused (declaration builtin)
# expect: fail declaration builtin
declare X=$(cat "$1") || exit 1
