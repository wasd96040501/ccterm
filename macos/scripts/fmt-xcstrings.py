#!/usr/bin/env python3
"""Deterministic formatter for .xcstrings files.

Xcode's xcstrings serializer differs between versions, which causes noisy
diffs whenever anyone opens the catalog. We normalize to a stable format
(JSON, 2-space indent, sorted keys, UTF-8) so CI can enforce a canonical
representation regardless of which Xcode wrote the file last.

Usage:
  fmt-xcstrings.py <file> [<file> ...]          # rewrite in place
  fmt-xcstrings.py --check <file> [<file> ...]  # exit 1 if any file differs
"""
import json
import sys
from pathlib import Path


def format_text(raw: str) -> str:
    data = json.loads(raw)
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    args = sys.argv[1:]
    check = False
    if args and args[0] == "--check":
        check = True
        args = args[1:]
    if not args:
        print("usage: fmt-xcstrings.py [--check] <file> [<file> ...]", file=sys.stderr)
        return 2

    bad = []
    for path_str in args:
        path = Path(path_str)
        original = path.read_text(encoding="utf-8")
        formatted = format_text(original)
        if original == formatted:
            continue
        if check:
            bad.append(path_str)
        else:
            path.write_text(formatted, encoding="utf-8")
            print(f"formatted {path_str}")

    if check and bad:
        print("xcstrings not formatted (run `make fmt`):", file=sys.stderr)
        for p in bad:
            print(f"  {p}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
