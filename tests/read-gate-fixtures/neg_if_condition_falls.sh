# refused: then branch does not refuse
# expect: fail falls through the if
if cat "$1"; then echo a; fi
