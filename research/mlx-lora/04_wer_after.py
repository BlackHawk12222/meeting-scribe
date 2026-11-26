"""Step 4: reload base model + saved adapter, measure held-out WER, then write the
combined result JSON (out/result.json): WER before/after, adapter MB, sec/step, peak memory."""
import json
import os

import mlx.core as mx

import common as C


def main():
    dev = C.setup_device()
    tr = json.loads((C.OUT / "train.json").read_text())
    model, _ = C.load_model()
    layers = tr["layers"] if tr["layers"] != "all" else None
    C.apply_lora(model, tr["rank"], tr["alpha"], tr["targets"], layers)
    model.load_weights(str(C.OUT / "adapter.safetensors"), strict=False)
    after = {"heldout": C.evaluate(model, C.load_split("heldout")),
             "train": C.evaluate(model, C.load_split("train"))}
    C.write_json(C.OUT / "wer_after.json", {"label": C.LABEL, "device": dev, **after})

    before = json.loads((C.OUT / "wer_before.json").read_text())
    load = json.loads((C.OUT / "load.json").read_text()) if (C.OUT / "load.json").exists() else {}
    ds = json.loads((C.DATA / "dataset_info.json").read_text())
    mb = 1024 * 1024
    peak = max(tr.get("peak_mlx_bytes", -1), 0)
    result = {
        "label": C.LABEL,
        "note": "All numbers: " + C.LABEL + ". Not measured on a user's Mac.",
        "env": {k: load.get(k) for k in ("python", "platform", "machine", "mlx", "parakeet_mlx",
                                         "metal_available", "device", "model", "dtype")},
        "dataset": ds,
        "autograd_probe": load.get("autograd"),
        "lora": {k: tr[k] for k in ("rank", "alpha", "lr", "targets", "layers", "wrapped_layers", "trainable_params")},
        "training": {k: tr[k] for k in ("steps_planned", "steps_done", "loss_first", "loss_last",
                                        "loss_mean_first_window", "loss_mean_last_window", "window",
                                        "loss_curve_every_10", "train_wall_seconds")},
        "sec_per_step_mean": tr["sec_per_step_mean"],
        "sec_per_step_median": tr["sec_per_step_median"],
        "first_step_sec": tr["first_step_sec"],
        "peak_mlx_memory_mb": round(peak / mb, 1) if peak else None,
        "peak_rss_mb": round(tr["peak_rss_bytes"] / mb, 1),
        "adapter_mb_fp32": round(tr["adapter_bytes_fp32"] / mb, 2),
        "adapter_mb_fp16": round(tr["adapter_bytes_fp16"] / mb, 2),
        "wer_heldout_before": round(before["heldout"]["wer"], 4),
        "wer_heldout_after": round(after["heldout"]["wer"], 4),
        "term_acc_heldout_before": round(before["heldout"]["term_accuracy"], 4),
        "term_acc_heldout_after": round(after["heldout"]["term_accuracy"], 4),
        "wer_train_before": round(before["train"]["wer"], 4),
        "wer_train_after": round(after["train"]["wer"], 4),
        "heldout_rows": [{"ref": b["ref"], "before": b["hyp"], "after": a["hyp"]}
                         for b, a in zip(before["heldout"]["rows"], after["heldout"]["rows"])],
    }
    C.write_json(C.OUT / "result.json", result)
    print(json.dumps({k: v for k, v in result.items() if k not in ("heldout_rows", "dataset")}, indent=2))
    for r in result["heldout_rows"]:
        print(" REF   :", r["ref"], "\n BEFORE:", r["before"], "\n AFTER :", r["after"])


if __name__ == "__main__":
    main()
