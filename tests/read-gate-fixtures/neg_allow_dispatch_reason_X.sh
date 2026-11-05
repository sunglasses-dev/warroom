# an allow entry (reason X) cannot clear a dispatch line: the entry is invalid and the occurrence stays unlisted
# expect: fail cannot be listed
# allow: X line=4 idx=0
eval "$1"
