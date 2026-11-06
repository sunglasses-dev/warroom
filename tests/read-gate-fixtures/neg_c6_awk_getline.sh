# counterexample C6: refused (cannot be audited)
# expect: fail cannot be audited
awk 'BEGIN { while ((getline l < ARGV[1]) > 0) print l }' "$1" || exit 1
