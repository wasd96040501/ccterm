"""Numbers only: recall and accuracy per arm, from one or more graded phases.

    aggregate.py <run-dir> <phase> [<phase> ...]

A case counts toward recall when its grader judged it valid (`case_ok`) and the
source arm found it (calibration: a seed the source reader misses is too subtle or
not a defect). Raw recall over every valid case is printed too. Prints no case
content, so it is safe on the holdout set."""
import collections, json, pathlib, sys

run = pathlib.Path(sys.argv[1])
grades, mapping = {}, {}
for phase in sys.argv[2:]:
    base = run / phase
    mapping.update(json.loads((base / "mapping.json").read_text()))
    for g in (base / "grades").glob("*.json"):
        d = json.loads(g.read_text())
        grades.setdefault(d["case"], {"case_ok": d["case_ok"], "reviews": {}})
        grades[d["case"]]["case_ok"] &= d["case_ok"]
        grades[d["case"]]["reviews"].update(d["reviews"])

dim = {c: json.loads((run / c / "key.json").read_text())["dimension"] for c in grades}
source_hit = {c: any(r["hit"] for lab, r in g["reviews"].items() if mapping.get(f"{c}.{lab}") == "source")
              for c, g in grades.items()}

stats = collections.defaultdict(lambda: collections.Counter())
for c, g in grades.items():
    for lab, r in g["reviews"].items():
        arm = mapping.get(f"{c}.{lab}")
        if arm is None:
            continue
        s = stats[arm]
        for a in r.get("accuracy", []):
            s[f"acc_{a}"] += 1
        if dim[c] == "control" or not g["case_ok"]:
            continue
        s["raw_n"] += 1
        s["raw_hit"] += r["hit"]
        if source_hit[c] or arm == "source":
            s["n"] += 1
            s["hit"] += r["hit"]
            s[f"n_{dim[c]}"] += 1
            s[f"hit_{dim[c]}"] += r["hit"]

valid = sum(g["case_ok"] for c, g in grades.items() if dim[c] != "control")
calib = sum(g["case_ok"] and source_hit[c] for c, g in grades.items() if dim[c] != "control")
print(f"cases graded {len(grades)}  valid seeds {valid}  calibrated (source found) {calib}")
pct = lambda a, b: f"{a}/{b}" + (f" ({100 * a // b}%)" if b else "")
print(f"{'arm':<14}{'recall':<14}{'raw':<14}{'tree':<10}{'layout':<10}{'data':<10}{'acc true/false/unv':<20}")
for arm, s in sorted(stats.items()):
    acc = f"{s['acc_true']}/{s['acc_false']}/{s['acc_unverifiable']}"
    print(f"{arm:<14}{pct(s['hit'], s['n']):<14}{pct(s['raw_hit'], s['raw_n']):<14}"
          f"{pct(s['hit_component-tree'], s['n_component-tree']):<10}{pct(s['hit_layout'], s['n_layout']):<10}"
          f"{pct(s['hit_data'], s['n_data']):<10}{acc:<20}")
