# D entry in a function that a literal trap action calls inside a group that writes to a file
# expect: fail in a trap action sends its output to a file
# allow: D line=4 idx=0
say() { echo "at $(date +%H:%M)"; }
trap '{ say; } >"$CUR.log"' EXIT
