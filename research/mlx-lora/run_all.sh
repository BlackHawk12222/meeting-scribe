#!/usr/bin/env bash
# Runs the whole feasibility test. Logs go to out/logs/, the summary to out/result.json.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out/logs
run() { local n=$1; shift; echo "=== $n ==="; python -u "$@" 2>&1 | tee "out/logs/$n.log"; }
run 01_make_dataset 01_make_dataset.py
run 00_load_model   00_load_model.py
run 02_wer_before   02_wer_before.py
run 03_train_lora   03_train_lora.py
run 04_wer_after    04_wer_after.py
