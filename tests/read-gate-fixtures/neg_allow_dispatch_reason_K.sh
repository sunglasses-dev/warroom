# an allow entry (reason K) cannot clear a dispatch line: the entry is invalid and the occurrence stays unlisted
# expect: fail cannot be listed
# allow: K line=4 idx=0
eval "$1"
