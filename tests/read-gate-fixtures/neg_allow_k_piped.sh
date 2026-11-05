# K entry, same statement, but a stage of a pipeline
# expect: fail stage of a pipeline
# allow: K line=4 idx=0
IFS=$(printf '\t') | cat
