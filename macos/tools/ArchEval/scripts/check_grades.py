"""Which graded cases miss a review (a grader that ran before every review was written).

    check_grades.py <run-dir> <phase>"""
import json, pathlib, sys

base = pathlib.Path(sys.argv[1]) / sys.argv[2]
mapping = json.loads((base / "mapping.json").read_text())
for g in sorted((base / "grades").glob("*.json")):
    d = json.loads(g.read_text())
    want = {k.split(".", 1)[1] for k in mapping if k.split(".", 1)[0] == d["case"]}
    missing = sorted(want - set(d["reviews"]))
    print(d["case"], "ok" if not missing else f"missing {missing}", "" if d["case_ok"] else "CASE NOT OK")
