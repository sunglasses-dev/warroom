# D entry in a group whose stderr goes to a descriptor that was opened on a file
# expect: fail sends its output to a file
# allow: D line=5 idx=0
exec 3>"$CUR.log"
{ echo "at $(date +%H:%M)"; } 2>&3
