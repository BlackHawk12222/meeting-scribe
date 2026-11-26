"""Step 0: load Parakeet TDT 0.6B v2 in MLX and prove it runs.

Checks: weights load from Hugging Face, tokenizer.model matches the joint vocabulary,
greedy TDT decoding works, and MLX autograd reaches the encoder (one backward pass of
the TDT loss with a gradient on an encoder weight). Writes out/load.json.
"""
import time

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten

import common as C


def main():
    dev = C.setup_device()
    info = C.env_info()
    model, load_s = C.load_model()
    sp = C.load_tokenizer(model)
    n_params = sum(v.size for _, v in tree_flatten(model.parameters()))
    out = {**info, "device": dev, "load_seconds": round(load_s, 2), "params": int(n_params),
           "encoder_layers": len(model.encoder.layers), "durations": model.durations,
           "vocab": len(model.vocabulary), "dtype": str(model.joint.enc.weight.dtype)}

    # smoke transcription of the first held-out clip if the dataset exists
    try:
        it = C.load_split("heldout")[0]
        t0 = time.time()
        out["smoke_ref"] = it["text"]
        out["smoke_hyp"] = C.transcribe(model, C.DATA / it["wav"])
        out["smoke_seconds"] = round(time.time() - t0, 2)
        mel = C.mel_for(model, C.DATA / it["wav"]).astype(model.joint.enc.weight.dtype)
        ids = sp.encode(it["text"])

        # autograd probe: unfreeze ONE encoder weight and backprop the TDT loss into it
        model.freeze()
        model.encoder.layers[-1].self_attn.linear_q.unfreeze()
        blank = len(model.vocabulary)

        def lf(m):
            j, T = C.forward_joint(m, mel, ids)
            return C.tdt_loss(j, [ids], [T], [len(ids)], blank, m.durations)[0]

        t0 = time.time()
        loss, grads = nn.value_and_grad(model, lf)(model)
        g = dict(tree_flatten(grads))
        gn = sum(float(mx.sum(v.astype(mx.float32) ** 2)) for v in g.values()) ** 0.5
        out["autograd"] = {"ok": bool(gn > 0 and gn == gn), "loss": float(loss), "grad_norm": gn,
                           "grad_keys": list(g.keys()), "seconds": round(time.time() - t0, 2)}
    except FileNotFoundError:
        out["smoke"] = "dataset not built yet"
    out["peak_mlx_bytes"] = C.peak_mlx_bytes()
    out["peak_rss_bytes"] = C.rss_peak_bytes()
    C.write_json(C.OUT / "load.json", out)
    print({k: v for k, v in out.items() if k != "autograd"})
    print("autograd:", out.get("autograd"))


if __name__ == "__main__":
    main()
