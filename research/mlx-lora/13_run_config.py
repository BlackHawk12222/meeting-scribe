"""Step two: train one LoRA config (or none = base model) and score it on every eval split.

Usage: python 13_run_config.py NAME [SEED]
  NAME = base | A | B | C   (see CONFIGS)
Writes out/configs/NAME_sSEED/result.json (+ train_log.jsonl, adapter_fp16.safetensors).

Eval splits: heldout_unseen (domain, voices not in training), heldout_same (domain, training
voice), regression (everyday English, unseen voices), libri (LibriSpeech test-clean, if fetched).
"""
import json
import math
import os
import random
import sys
import time

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

import common as C

CONFIGS = {
    "base": None,
    # A: step-one settings
    "A": {"layers": "all", "steps": 300, "replay": 0.0},
    # B: LoRA on the last 12 of 24 encoder blocks, half the steps
    "B": {"layers": "last:12", "steps": 150, "replay": 0.0},
    # C: B + ~30% everyday-English replay clips (training voice) as a regularizer
    "C": {"layers": "last:12", "steps": 150, "replay": 0.3},
}
EVAL_SPLITS = ["heldout_unseen", "heldout_same", "regression", "libri"]


def train(model, sp, cfg, seed, outdir):
    r = int(os.environ.get("LORA_RANK", 8))
    alpha = float(os.environ.get("LORA_ALPHA", 16))
    lr = float(os.environ.get("LR", 2e-4))
    warm = int(os.environ.get("WARMUP", 20))
    cap = float(os.environ.get("MAX_MINUTES", 30)) * 60
    steps = cfg["steps"]
    mx.random.seed(seed)
    layers = C.parse_layers(cfg["layers"], len(model.encoder.layers))
    n_wrapped = C.apply_lora(model, r, alpha, None, layers)
    n_train = sum(v.size for v in C.lora_params(model).values())
    print(f"LoRA r={r} layers={cfg['layers']} ({n_wrapped} Linear, {n_train:,} params) steps={steps} "
          f"replay={cfg['replay']} seed={seed}")

    dtype = model.joint.enc.weight.dtype
    blank = len(model.vocabulary)

    def prep(split):
        out = [(C.mel_for(model, C.DATA / it["wav"]).astype(dtype), sp.encode(it["text"]), it["id"])
               for it in C.load_split(split)]
        mx.eval([d[0] for d in out])
        return out

    dom = prep("train")
    rep = prep("replay") if cfg["replay"] > 0 else []

    def loss_fn(m, mel, ids):
        j, T = C.forward_joint(m, mel, ids)
        return C.tdt_loss(j, [ids], [T], [len(ids)], blank, m.durations)[0] / len(ids)

    sched = optim.join_schedules([optim.linear_schedule(lr * 0.05, lr, warm),
                                  optim.cosine_decay(lr, max(steps - warm, 1), lr * 0.1)], [warm])
    opt = optim.AdamW(learning_rate=sched, weight_decay=0.0)
    vg = nn.value_and_grad(model, loss_fn)

    rng = random.Random(seed)
    orders = {"dom": [], "rep": []}

    def draw(kind, pool):
        if not orders[kind]:
            orders[kind] = list(range(len(pool)))
            rng.shuffle(orders[kind])
        return pool[orders[kind].pop()]

    C.reset_peak()
    log, n_rep = [], 0
    t_start = time.time()
    with open(outdir / "train_log.jsonl", "w") as logf:
        for step in range(steps):
            use_rep = bool(rep) and rng.random() < cfg["replay"]
            mel, ids, cid = draw("rep", rep) if use_rep else draw("dom", dom)
            n_rep += use_rep
            t0 = time.time()
            loss, grads = vg(model, mel, ids)
            grads, gnorm = optim.clip_grad_norm(grads, 1.0)
            opt.update(model, grads)
            mx.eval(model.trainable_parameters(), opt.state, loss)
            rec = {"step": step + 1, "loss": float(loss), "grad_norm": float(gnorm),
                   "sec": round(time.time() - t0, 3), "clip": cid}
            logf.write(json.dumps(rec) + "\n")
            if not math.isfinite(rec["loss"]):
                raise RuntimeError(f"non-finite loss at step {step+1}")
            log.append(rec)
            if step < 3 or (step + 1) % 25 == 0:
                print(f"step {step+1:4d} loss {rec['loss']:.4f} gnorm {rec['grad_norm']:.3f} {rec['sec']:.2f}s")
            if time.time() - t_start > cap:
                print("MAX_MINUTES reached")
                break
    params = C.lora_params(model)
    mx.save_safetensors(str(outdir / "adapter_fp16.safetensors"),
                        {k: v.astype(mx.float16) for k, v in params.items()})
    dl = [x["loss"] for x in log if not x["clip"].startswith("replay")]
    k = max(1, min(20, len(dl) // 5))
    return {"rank": r, "alpha": alpha, "lr": lr, "layers": cfg["layers"], "wrapped_layers": n_wrapped,
            "trainable_params": int(n_train), "steps_done": len(log), "replay_frac": cfg["replay"],
            "replay_steps": n_rep, "domain_loss_first_window": round(sum(dl[:k]) / k, 4),
            "domain_loss_last_window": round(sum(dl[-k:]) / k, 4),
            "train_wall_seconds": round(time.time() - t_start, 1),
            "sec_per_step_median": sorted(x["sec"] for x in log)[len(log) // 2],
            "peak_mlx_mb": round(max(C.peak_mlx_bytes(), 0) / 2**20, 1)}


def main():
    name = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    cfg = CONFIGS[name]
    dev = C.setup_device()
    outdir = C.OUT / "configs" / (name if cfg is None else f"{name}_s{seed}")
    outdir.mkdir(parents=True, exist_ok=True)
    model, _ = C.load_model()
    sp = C.load_tokenizer(model)
    res = {"label": C.LABEL, "device": dev, "config": name, "seed": seed, "settings": cfg}
    if cfg is not None:
        res["training"] = train(model, sp, cfg, seed, outdir)
    res["eval"] = {}
    for split in EVAL_SPLITS:
        if not (C.DATA / f"{split}.jsonl").exists():
            continue
        ev = C.evaluate(model, C.load_split(split))
        res["eval"][split] = ev
        print(f"{name} s{seed} {split}: WER {ev['wer']*100:.2f}% ({ev['word_errors']}/{ev['words']})"
              + (f", terms {ev['terms_hit']}/{ev['terms_total']}" if ev["terms_total"] else ""))
    C.write_json(outdir / "result.json", res)


if __name__ == "__main__":
    main()
