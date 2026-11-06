# D entry in a function whose only call is captured by a substitution that is written to a file afterwards
# expect: fail must be printed by echo or printf
# allow: D line=4 idx=0
say() { echo "at $(date +%H:%M)"; }
msg=$(say)
echo "$msg" > "$CUR.log"
