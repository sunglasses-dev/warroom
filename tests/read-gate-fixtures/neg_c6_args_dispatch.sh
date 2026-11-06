# counterexample C6: refused (cannot be audited)
# expect: fail cannot be audited
run() { "$@" 8>&- 9>&-; }
run cat "$1"
