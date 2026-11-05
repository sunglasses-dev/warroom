# the success test is OR-ed with true: the branch exits 0 whatever the saved status was
# expect: fail does not test it
x=$(cat "$1"); rc=$?
if [ "$rc" = 0 ] || true; then exit 0; fi
exit 1
