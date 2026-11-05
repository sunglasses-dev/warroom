# D entry inside a command substitution whose value is written to a file afterwards
# expect: fail must be printed by echo or printf
# allow: D line=4 idx=1
msg=$( { echo "at $(date +%H:%M)"; } 2>&1 )
echo "$msg" > "$CUR.log"
