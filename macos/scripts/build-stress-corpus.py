#!/usr/bin/env python3
"""Fetch public-domain prose and emit a stress-test corpus for NativeTranscript2.

Output: macos/ccterm/Resources/transcript_stress_corpus.txt

Format: one entry per line, tab-separated:
    H<TAB>heading text
    P<TAB>paragraph text

Targets ~1500 entries totaling ~3-4 MB plain text (≈1M tokens) so the renderer
gets a real workload. Pulled from Project Gutenberg (public domain). Idempotent
— re-runs read the cached `_raw_*.txt` files in this directory unless --refetch.
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CACHE_DIR = SCRIPT_DIR / ".stress_corpus_cache"
OUT_FILE = SCRIPT_DIR.parent / "ccterm" / "Resources" / "transcript_stress_corpus.txt"

SOURCES = [
    # War and Peace (Tolstoy, English) — ~3.2 MB plain text. Long, varied
    # paragraph length, plenty of dialogue + narrative + chapter headings.
    ("war_and_peace", "https://www.gutenberg.org/files/2600/2600-0.txt"),
]

CHAPTER_RE = re.compile(
    r"^(BOOK [A-Z]+|CHAPTER [IVXLCDM]+|EPILOGUE.*|PART [A-Z]+).*",
    re.IGNORECASE,
)


def fetch(name: str, url: str, refetch: bool) -> str:
    cache = CACHE_DIR / f"{name}.txt"
    if cache.exists() and not refetch:
        return cache.read_text(encoding="utf-8")
    print(f"  fetching {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": "ccterm-stress/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    text = data.decode("utf-8", errors="replace")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache.write_text(text, encoding="utf-8")
    return text


def strip_gutenberg(text: str) -> str:
    start = re.search(r"\*\*\* START OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text)
    end = re.search(r"\*\*\* END OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text)
    if start:
        text = text[start.end():]
    if end:
        text = text[:end.start()]
    return text


def split_paragraphs(text: str) -> list[str]:
    """Split on blank lines, re-flow hard-wrapped lines into one paragraph each."""
    out: list[str] = []
    for chunk in re.split(r"\n\s*\n", text):
        flat = " ".join(line.strip() for line in chunk.splitlines() if line.strip())
        if flat:
            out.append(flat)
    return out


def classify(p: str) -> tuple[str, str]:
    if len(p) < 100 and CHAPTER_RE.match(p.strip()):
        return ("H", p)
    return ("P", p)


def split_long(p: str, cap: int) -> list[str]:
    """Split an over-cap paragraph at sentence boundaries, never above `cap`."""
    sentences = re.split(r"(?<=[.!?])\s+", p)
    out: list[str] = []
    buf = ""
    for s in sentences:
        if not s:
            continue
        if not buf:
            buf = s
        elif len(buf) + 1 + len(s) <= cap:
            buf += " " + s
        else:
            out.append(buf)
            buf = s
    if buf:
        out.append(buf)
    return out


def merge_to_target(
    paragraphs: list[str], target: int, hard_cap: int
) -> list[str]:
    """Greedy-join consecutive paragraphs until the buffer reaches `target`,
    never crossing `hard_cap`. Keeps text-like rhythm but pushes per-block
    size up to chat-message scale (raw Gutenberg paragraphs are ~280 chars
    avg, far shorter than realistic chat output)."""
    out: list[str] = []
    buf = ""
    for p in paragraphs:
        if not buf:
            buf = p
            continue
        if len(buf) >= target or len(buf) + 2 + len(p) > hard_cap:
            out.append(buf)
            buf = p
        else:
            buf = buf + "  " + p
    if buf:
        out.append(buf)
    return out


def build(
    max_entries: int, target_chars: int, hard_cap: int, refetch: bool
) -> list[tuple[str, str]]:
    raw_chunks: list[str] = []
    for name, url in SOURCES:
        text = fetch(name, url, refetch)
        text = strip_gutenberg(text)
        raw_chunks.append(text)
    paragraphs = split_paragraphs("\n\n".join(raw_chunks))
    print(f"  raw paragraphs: {len(paragraphs)}", file=sys.stderr)

    MIN_LEN = 40
    cleaned: list[str] = []
    for p in paragraphs:
        p = re.sub(r"\s+", " ", p).strip()
        if len(p) < MIN_LEN:
            continue
        if len(p) <= hard_cap:
            cleaned.append(p)
        else:
            cleaned.extend(c for c in split_long(p, hard_cap) if len(c) >= MIN_LEN)

    merged = merge_to_target(cleaned, target_chars, hard_cap)

    entries: list[tuple[str, str]] = []
    for p in merged:
        entries.append(classify(p))
        if len(entries) >= max_entries:
            break
    return entries


def write(entries: list[tuple[str, str]]) -> None:
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with OUT_FILE.open("w", encoding="utf-8") as f:
        for kind, text in entries:
            text = text.replace("\t", " ").replace("\n", " ")
            f.write(f"{kind}\t{text}\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=1500, help="max entries (default 1500)")
    ap.add_argument("--target", type=int, default=2400,
                    help="target chars per merged entry (default 2400)")
    ap.add_argument("--cap", type=int, default=4500,
                    help="hard char cap per entry (default 4500)")
    ap.add_argument("--refetch", action="store_true", help="bypass cache")
    args = ap.parse_args()

    entries = build(args.max, args.target, args.cap, args.refetch)
    write(entries)

    chars = sum(len(t) for _, t in entries)
    headings = sum(1 for k, _ in entries if k == "H")
    paragraphs = sum(1 for k, _ in entries if k == "P")
    # Rough: English ≈ 4 chars / token. Coarse upper bound.
    approx_tokens = chars // 4
    size_mb = OUT_FILE.stat().st_size / (1024 * 1024)
    print(
        f"wrote {len(entries)} entries "
        f"({headings} H + {paragraphs} P), "
        f"{chars:,} chars (~{approx_tokens:,} tokens), "
        f"{size_mb:.2f} MB → {OUT_FILE}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
