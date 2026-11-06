# M: stdin drain
# expect: pass
# allow: M line=4 idx=0
cat >/dev/null
echo done
