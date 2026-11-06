# the condition holds a second command: the branch runs on the status of `false`, not of the saved status
# expect: fail does not test it
x=$(cat "$1"); rc=$?
if [ "$rc" != 0 ]; false; then exit 1; fi
printf "consumed=<%s>\n" "$x"
