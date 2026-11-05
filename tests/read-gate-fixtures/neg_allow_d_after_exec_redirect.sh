# D entry after a top-level exec that points stderr at a file: the file envelope refuses the whole file
# envelope: bin/_lib.sh
# expect: fail outside the envelope
# allow: D line=6 idx=0
exec 2>>"$CUR.log"
echo "at $(date +%H:%M)"
