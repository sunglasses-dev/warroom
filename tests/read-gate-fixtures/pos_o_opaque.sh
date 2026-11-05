# O: a python program with pinned text
# expect: pass
# allow: O line=4 idx=0
v=$(python3 -I -c 'print(1)' "$1")
echo "$v"
