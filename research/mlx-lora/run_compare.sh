#!/usr/bin/env bash
# Step two: regression check + overfitting configs (A, B, C), then a second seed for the winner.
# Logs go to out/logs/, the summary to out/compare.json / out/compare.md.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out/logs
run() { local n=$1; shift; echo "=== $n ==="; python -u "$@" 2>&1 | tee "out/logs/$n.log"; }
run 11_make_dataset_v2 11_make_dataset_v2.py
run base   13_run_config.py base
for c in ${CONFIGS:-A B C}; do run "${c}_s0" 13_run_config.py "$c" 0; done
# EXTRA_RUNS="B:1 C:1" adds more config:seed runs (e.g. second seeds for configs that were not the winner)
for cs in ${EXTRA_RUNS:-}; do run "${cs%%:*}_s${cs##*:}" 13_run_config.py "${cs%%:*}" "${cs##*:}"; done
run 14_summarize 14_summarize.py
w=$(cat out/winner.txt)
if [ -n "$w" ] && [ "${SECOND_SEED:-1}" = "1" ]; then
  run "${w}_s1" 13_run_config.py "$w" 1
  run 14_summarize_final 14_summarize.py
fi
