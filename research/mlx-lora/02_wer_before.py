"""Step 2: WER of the unmodified model on the held-out (and training) clips. Writes out/wer_before.json."""
import common as C


def main():
    dev = C.setup_device()
    model, _ = C.load_model()
    res = {"label": C.LABEL, "device": dev,
           "heldout": C.evaluate(model, C.load_split("heldout")),
           "train": C.evaluate(model, C.load_split("train"))}
    C.write_json(C.OUT / "wer_before.json", res)
    for k in ("heldout", "train"):
        r = res[k]
        print(f"{k}: WER {r['wer']:.3f} ({r['word_errors']}/{r['words']}), terms {r['terms_hit']}/{r['terms_total']}")
    for row in res["heldout"]["rows"]:
        print(" REF:", row["ref"], "\n HYP:", row["hyp"])


if __name__ == "__main__":
    main()
