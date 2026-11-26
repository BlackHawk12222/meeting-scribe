"""Step 3: attach LoRA to the encoder attention projections and train with the TDT loss.

Env knobs: LORA_RANK (8), LORA_ALPHA (16), LORA_LAYERS (all | last:N | 0,1,2),
LORA_TARGETS (comma list, default q,k,v,out of self_attn), STEPS (300), LR (2e-4),
WARMUP (20), MAX_MINUTES (wall-clock cap, 75).
Batch size is 1: parakeet-mlx's encoder has no padding mask, so padded batches would leak.
Writes out/adapter.safetensors, out/train_log.jsonl, out/train.json.
"""
import json
import math
import os
import random
import time

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

import common as C


def main():
    dev = C.setup_device()
    r = int(os.environ.get("LORA_RANK", 8))
    alpha = float(os.environ.get("LORA_ALPHA", 16))
    steps = int(os.environ.get("STEPS", 300))
    lr = float(os.environ.get("LR", 2e-4))
    warm = int(os.environ.get("WARMUP", 20))
    cap = float(os.environ.get("MAX_MINUTES", 75)) * 60
    targets = os.environ.get("LORA_TARGETS")
    targets = [f"self_attn.{t}" if "." not in t else t for t in targets.split(",")] if targets else None

    model, _ = C.load_model()
    sp = C.load_tokenizer(model)
    layers = C.parse_layers(os.environ.get("LORA_LAYERS", "all"), len(model.encoder.layers))
    n_wrapped = C.apply_lora(model, r, alpha, targets, layers)
    params = C.lora_params(model)
    n_train = sum(v.size for v in params.values())
    print(f"LoRA r={r} alpha={alpha}: {n_wrapped} Linear layers, {n_train:,} trainable params")

    dtype = model.joint.enc.weight.dtype
    blank = len(model.vocabulary)
    data = []
    for it in C.load_split("train"):
        data.append((C.mel_for(model, C.DATA / it["wav"]).astype(dtype), sp.encode(it["text"]), it["id"]))
    mx.eval([d[0] for d in data])

    def loss_fn(m, mel, ids):
        j, T = C.forward_joint(m, mel, ids)
        return C.tdt_loss(j, [ids], [T], [len(ids)], blank, m.durations)[0] / len(ids)

    sched = optim.join_schedules([optim.linear_schedule(lr * 0.05, lr, warm),
                                  optim.cosine_decay(lr, max(steps - warm, 1), lr * 0.1)], [warm])
    opt = optim.AdamW(learning_rate=sched, weight_decay=0.0)
    vg = nn.value_and_grad(model, loss_fn)

    rng = random.Random(0)
    order = []
    log = []
    C.reset_peak()
    t_start = time.time()
    logf = open(C.OUT / "train_log.jsonl", "w")
    done = 0
    for step in range(steps):
        if not order:
            order = list(range(len(data)))
            rng.shuffle(order)
        mel, ids, cid = data[order.pop()]
        t0 = time.time()
        loss, grads = vg(model, mel, ids)
        grads, gnorm = optim.clip_grad_norm(grads, 1.0)
        opt.update(model, grads)
        mx.eval(model.trainable_parameters(), opt.state, loss)
        dt = time.time() - t0
        rec = {"step": step + 1, "loss": float(loss), "grad_norm": float(gnorm), "sec": round(dt, 3),
               "lr": float(opt.learning_rate), "clip": cid}
        if not math.isfinite(rec["loss"]):
            rec["error"] = "non-finite loss"
            print(rec)
            logf.write(json.dumps(rec) + "\n")
            break
        log.append(rec)
        logf.write(json.dumps(rec) + "\n")
        logf.flush()
        done = step + 1
        if step < 5 or (step + 1) % 10 == 0:
            print(f"step {step+1:4d} loss {rec['loss']:.4f} gnorm {rec['grad_norm']:.3f} {dt:.2f}s")
        if time.time() - t_start > cap:
            print(f"stopping at step {step+1}: MAX_MINUTES reached")
            break
    logf.close()

    params = C.lora_params(model)
    adapter = C.OUT / "adapter.safetensors"
    mx.save_safetensors(str(adapter), params)
    mx.save_safetensors(str(C.OUT / "adapter_fp16.safetensors"), {k: v.astype(mx.float16) for k, v in params.items()})

    secs = [x["sec"] for x in log[5:]] or [x["sec"] for x in log]
    losses = [x["loss"] for x in log]

    def win(a, b):
        s = losses[a:b]
        return round(sum(s) / len(s), 4) if s else None

    k = max(1, min(20, len(losses) // 5))
    summary = {
        "label": C.LABEL, "device": dev, "rank": r, "alpha": alpha, "lr": lr, "steps_planned": steps,
        "steps_done": done, "wrapped_layers": n_wrapped, "trainable_params": int(n_train),
        "targets": targets or list(C.DEFAULT_TARGETS), "layers": layers or "all",
        "loss_first": losses[0] if losses else None, "loss_last": losses[-1] if losses else None,
        "loss_mean_first_window": win(0, k), "loss_mean_last_window": win(-k, None), "window": k,
        "loss_curve_every_10": [round(x["loss"], 4) for x in log[::10]],
        "sec_per_step_mean": round(sum(secs) / len(secs), 3) if secs else None,
        "sec_per_step_median": round(sorted(secs)[len(secs) // 2], 3) if secs else None,
        "first_step_sec": log[0]["sec"] if log else None,
        "train_wall_seconds": round(time.time() - t_start, 1),
        "peak_mlx_bytes": C.peak_mlx_bytes(), "peak_rss_bytes": C.rss_peak_bytes(),
        "adapter_bytes_fp32": adapter.stat().st_size,
        "adapter_bytes_fp16": (C.OUT / "adapter_fp16.safetensors").stat().st_size,
    }
    C.write_json(C.OUT / "train.json", summary)
    print(json.dumps({k: v for k, v in summary.items() if k != "loss_curve_every_10"}, indent=2))


if __name__ == "__main__":
    main()
