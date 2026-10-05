"""Per case and arm: hit or miss with the grader's note, and accuracy. Dev sets only —
it prints case content.

    detail.py <run-dir> <phase> [<phase> ...]"""
import json, pathlib, sys

run = pathlib.Path(sys.argv[1])
for phase in sys.argv[2:]:
    base = run / phase
    mapping = json.loads((base / "mapping.json").read_text())
    for g in sorted((base / "grades").glob("*.json")):
        d = json.loads(g.read_text())
        print(f"\n## {d['case']}  ok={d['case_ok']}  {d.get('case_note', '')}")
        for lab, r in sorted(d["reviews"].items(), key=lambda kv: mapping.get(f"{d['case']}.{kv[0]}", "")):
            arm = mapping.get(f"{d['case']}.{lab}", "?")
            acc = "".join({"true": "T", "false": "F", "unverifiable": "?"}[a] for a in r.get("accuracy", []))
            print(f"- {arm:<10} {lab} {'HIT ' if r['hit'] else 'miss'} [{acc}] {r.get('hit_note', '')}")
