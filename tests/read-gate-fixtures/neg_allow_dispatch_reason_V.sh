# an allow entry (reason V) cannot clear a dispatch line: the entry is invalid and the occurrence stays unlisted
# expect: fail cannot be listed
# allow: V line=4 idx=0
eval "$1"
