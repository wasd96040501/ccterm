"""Share of a map diff that is numeric churn only (line counts, sizes).

    numeric_noise.py <old-map-dir> <new-map-dir>

Pairs each removed line with an added line that is identical once digits are
masked; such pairs are churn, not architecture."""
import difflib, pathlib, re, sys

old, new = map(pathlib.Path, sys.argv[1:3])
mask = lambda s: re.sub(r"\d+", "#", s)
churn = real = 0
for f in sorted({p.relative_to(old) for p in old.rglob("*.md")} | {p.relative_to(new) for p in new.rglob("*.md")}):
    a = (old / f).read_text().splitlines() if (old / f).exists() else []
    b = (new / f).read_text().splitlines() if (new / f).exists() else []
    removed = [l for l in difflib.unified_diff(a, b, lineterm="", n=0) if l.startswith("-") and not l.startswith("---")]
    added = [l for l in difflib.unified_diff(a, b, lineterm="", n=0) if l.startswith("+") and not l.startswith("+++")]
    pool = {}
    for l in added:
        pool.setdefault(mask(l[1:]), []).append(l)
    for l in removed:
        k = mask(l[1:])
        if pool.get(k):
            pool[k].pop()
            churn += 2
        else:
            real += 1
    real += sum(len(v) for v in pool.values())
print(f"diff lines: {churn + real}  numeric churn: {churn}  structural: {real}")
