# MLX LoRA feasibility test (research only)

Question: can a small LoRA adapter be trained on NVIDIA Parakeet TDT 0.6B v2 with Apple MLX on a Mac?
Nothing here ships in Scribe.app; the app keeps running Parakeet through FluidAudio / Core ML.

| file | what it does |
|---|---|
| `common.py` | model loading (parakeet-mlx), WAV/mel, SentencePiece tokens, LoRA wrapper, pure-MLX TDT loss, WER |
| `00_load_model.py` | loads `mlx-community/parakeet-tdt-0.6b-v2`, smoke transcription, one autograd probe |
| `01_make_dataset.py` | 60 train + 10 held-out clips with macOS `say` (one voice), domain terms |
| `02_wer_before.py` | WER + term accuracy of the base model |
| `03_train_lora.py` | LoRA (rank 8, q/k/v/out of all 24 encoder attention blocks), TDT loss, logs loss/sec/memory |
| `04_wer_after.py` | reloads base + adapter, WER after, writes `out/result.json` |

Run: `pip install -r requirements.txt && ./run_all.sh` (macOS, Apple Silicon).
CI: `.github/workflows/mlx-feasibility.yml` (manual dispatch only).

The TDT loss follows NeMo's recursion (blank durations >= 1, token durations >= 0, the path ends
with a blank landing on the last frame). It matched a brute-force path enumeration on random
small trellises. NeMo's `omega` (RNNT-loss mixing) is not used; `sigma` defaults to 0.
Numbers from CI are from a GitHub-hosted virtual M1 with a synthetic `say` voice.
