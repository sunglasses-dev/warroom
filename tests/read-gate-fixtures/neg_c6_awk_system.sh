# counterexample C6: refused (cannot be audited)
# expect: fail cannot be audited
awk 'BEGIN { system("cat " ARGV[1]) }' "$1" || exit 1
