# refused: falls back
# expect: fail does not refuse
if ! x=$(cat "$1"); then echo bad; fi
echo "$x"
