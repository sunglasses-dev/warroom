# counterexample C6: refused (cannot be audited)
# expect: fail cannot be audited
builtin read -r a < "$1" || exit 1
