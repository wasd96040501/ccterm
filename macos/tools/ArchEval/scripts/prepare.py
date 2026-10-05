"""Build each case's review material: the patched sources and the maps of them.

    prepare.py <cases-dir> <run-dir> [--archmap <ArchMap package dir>]

For every case directory (one holding key.json, and patch.diff unless it is a
control) this writes:

    <run-dir>/<id>/src/macos       base sources with the patch applied
    <run-dir>/<id>/map-full/       `make arch SCOPE=app,Components,DisplayModels`
    <run-dir>/<id>/map-core3/      the same without units/ (index, tree, data, rules)

and <run-dir>/sizes.json with each variant's byte size. The ArchMap used is the
one in --archmap (default: the repo's), built in release first."""
import argparse, json, pathlib, shutil, subprocess

REPO = pathlib.Path(__file__).resolve().parents[4]
BASE = REPO / "build/arch-eval/base/macos"
SCOPE = "app,Components,DisplayModels"


def size(d: pathlib.Path) -> int:
    return sum(p.stat().st_size for p in d.rglob("*.md"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cases")
    ap.add_argument("run")
    ap.add_argument("--archmap", default=str(REPO / "macos/tools/ArchMap"))
    a = ap.parse_args()
    pkg = pathlib.Path(a.archmap)
    subprocess.run(["swift", "build", "-c", "release", "--package-path", str(pkg)], check=True, capture_output=True)
    binary = pkg / ".build/release/ArchMap"
    run = pathlib.Path(a.run)
    run.mkdir(parents=True, exist_ok=True)
    sizes = {}
    for case in sorted(pathlib.Path(a.cases).iterdir()):
        if not (case / "key.json").exists():
            continue
        out = run / case.name
        if out.exists():
            shutil.rmtree(out)
        (out / "src").mkdir(parents=True)
        subprocess.run(["cp", "-cR", str(BASE), str(out / "src/macos")], check=True)
        shutil.copy(case / "key.json", out / "key.json")
        patch = case / "patch.diff"
        if patch.exists() and patch.stat().st_size:
            shutil.copy(patch, out / "patch.diff")
            with patch.open() as f:
                subprocess.run(["patch", "-s", "-p1", "-d", str(out / "src")], stdin=f, check=True)
        full = out / "map-full"
        subprocess.run([str(binary), str(out / "src/macos"), str(full), SCOPE, ""], check=True, capture_output=True)
        core = out / "map-core3"
        core.mkdir()
        for name in ("index.md", "tree.md", "data.md", "rules.md"):
            shutil.copy(full / name, core / name)
        sizes[case.name] = {"full": size(full), "core3": size(core)}
        print(case.name, sizes[case.name])
    (run / "sizes.json").write_text(json.dumps(sizes, indent=2))


if __name__ == "__main__":
    main()
