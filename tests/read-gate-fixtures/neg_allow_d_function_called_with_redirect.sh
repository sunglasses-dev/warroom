# D entry inside a function whose only call carries a file redirection: the body runs with it
# expect: fail sends its output to a file
# allow: D line=4 idx=0
say() { echo "at $(date +%H:%M)"; }
say 2>"$CUR.log"
