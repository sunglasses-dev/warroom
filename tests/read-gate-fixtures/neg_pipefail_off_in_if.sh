# pipefail is switched off inside an if before the pipeline: the first stage's failure is dropped
# expect: fail pipeline stage
x=$(set -o pipefail; if true; then set +o pipefail; fi; cat "$1" | cat) || exit 1
printf "consumed=<%s>\n" "$x"
