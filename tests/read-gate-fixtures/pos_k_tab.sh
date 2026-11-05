# K: the literal tab
# expect: pass
# allow: K line=4 idx=0
TAB=$(printf '\t')
echo "$TAB" >/dev/null
