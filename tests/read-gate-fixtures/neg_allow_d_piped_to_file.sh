# D entry, same statement, but a stage of a pipeline that writes the value to a file
# expect: fail stage of a pipeline
# allow: D line=4 idx=0
echo "at $(date +%H:%M)" | tee state
