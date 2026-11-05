# K entry, same statement, but inside a group whose output goes to a file
# expect: fail sends its output to a file
# allow: K line=4 idx=0
{ IFS=$(printf '\t'); } > state
