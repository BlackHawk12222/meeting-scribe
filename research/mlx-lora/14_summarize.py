"""Step two: compare configs against the base model, apply the pass rule, pick a winner.

Pass rule: on every normal-English split (regression, and libri when present) the adapter's WER
may be at most 0.5 points (absolute) worse than the base model's.
Winner: among seed-0 configs that pass, the highest domain-term accuracy on the unseen-voice
held-out set, then the lowest unseen-voice held-out WER, then the smallest normal-English change.
Writes out/compare.json, out/compare.md and out/winner.txt (empty if nothing passes).
"""
import json

import common as C

NORMAL = ["regression", "libri"]
TOL = 0.005


def main():
    rows = {}
    for p in sorted((C.OUT / "configs").glob("*/result.json")):
        r = json.loads(p.read_text())
        rows[p.parent.name] = r
    base = rows["base"]["eval"]
    normal = [s for s in NORMAL if s in base]
    table = []
    for key, r in rows.items():
        ev = r["eval"]
        row = {"run": key, "config": r["config"], "seed": r["seed"],
               "settings": r.get("settings"), "training": r.get("training")}
        for s, e in ev.items():
            row[f"{s}_wer"] = round(e["wer"] * 100, 2)
            if e["terms_total"]:
                row[f"{s}_terms"] = round(e["term_accuracy"] * 100, 1)
        deltas = {s: round((ev[s]["wer"] - base[s]["wer"]) * 100, 2) for s in normal}
        row["normal_delta_pts"] = deltas
        row["pass"] = all(ev[s]["wer"] - base[s]["wer"] <= TOL + 1e-9 for s in normal)
        table.append(row)

    cands = [t for t in table if t["config"] != "base" and t["seed"] == 0 and t["pass"]]
    cands.sort(key=lambda t: (-t.get("heldout_unseen_terms", 0), t["heldout_unseen_wer"],
                              max(t["normal_delta_pts"].values() or [0])))
    winner = cands[0]["config"] if cands else ""
    if not winner:  # nothing passes: second seed goes to the config that hurt normal English least
        rest = [t for t in table if t["config"] != "base" and t["seed"] == 0]
        rest.sort(key=lambda t: max(t["normal_delta_pts"].values() or [0]))
        fallback = rest[0]["config"] if rest else ""
    else:
        fallback = ""
    (C.OUT / "winner.txt").write_text(winner or fallback)

    cols = ["heldout_unseen_wer", "heldout_unseen_terms", "heldout_same_wer", "heldout_same_terms",
            "regression_wer", "libri_wer"]
    md = ["All numbers: " + C.LABEL, "",
          "| run | " + " | ".join(cols) + " | normal-English delta (pts) | pass |",
          "|---|" + "---|" * (len(cols) + 2)]
    for t in table:
        md.append(f"| {t['run']} | " + " | ".join(str(t.get(c, "-")) for c in cols)
                  + f" | {t['normal_delta_pts']} | {'yes' if t['pass'] else 'NO'} |")
    md.append("")
    md.append(f"winner (seed 0, passing): {winner or 'none'}" + (f"; second seed run on {fallback}" if fallback else ""))
    out = {"label": C.LABEL, "pass_rule": f"normal-English WER <= base + {TOL*100} pts on {normal}",
           "winner": winner or None, "second_seed_target": winner or fallback or None, "rows": table}
    C.write_json(C.OUT / "compare.json", out)
    (C.OUT / "compare.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))
    # examples where the adapters changed normal English
    for s in normal:
        for key, r in rows.items():
            if key == "base":
                continue
            for b, a in zip(rows["base"]["eval"][s]["rows"], r["eval"][s]["rows"]):
                if b["hyp"] != a["hyp"]:
                    print(f"[{key} {s}] REF {a['ref']}\n   BASE {b['hyp']}\n   LORA {a['hyp']}")


if __name__ == "__main__":
    main()
