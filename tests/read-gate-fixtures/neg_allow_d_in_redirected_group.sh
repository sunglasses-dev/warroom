# D entry, same statement, but inside a group whose output goes to a file: the partial clock reaches state
# expect: fail sends its output to a file
# allow: D line=4 idx=0
{ echo "at $(date +%H:%M)"; } > state
