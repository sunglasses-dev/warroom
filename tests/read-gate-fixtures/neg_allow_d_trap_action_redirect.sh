# D entry in a function that a literal trap action calls with a file redirection: the clock lands in the log
# expect: fail in a trap action sends its output to a file
# allow: D line=4 idx=0
say() { echo "at $(date +%H:%M)"; }
trap 'say 2>>"$CUR.log"' EXIT
