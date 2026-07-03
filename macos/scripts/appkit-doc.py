#!/usr/bin/env python3
"""Look up an AppKit symbol from Apple's official documentation.

Fetches Apple's DocC render-JSON (the same structured data the developer.apple.com
docs site consumes) and prints a compact Markdown summary. Two query shapes:

    appkit-doc.py NSStackView              # class overview + members grouped by topic
    appkit-doc.py NSStackView.orientation  # one member: full declaration + discussion + params

Class pages list every property/method (with a one-line abstract each), grouped
under Apple's own topic headings. Member pages carry the full documentation —
multi-paragraph discussion, per-parameter notes, exceptions, See Also.

Source is Apple's own render-JSON, so the output is first-party, not a guess.
Responses are cached under /tmp (see CACHE_DIR) to avoid re-hitting the network
when you look up the same symbol repeatedly; the cache is disposable and refills
on the next miss.

Usage:
  appkit-doc.py <Symbol>                 # e.g. NSStackView, NSViewController
  appkit-doc.py <Symbol>.<member>        # e.g. NSStackView.orientation
  appkit-doc.py <Symbol> --no-cache      # bypass the /tmp cache for this call
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Apple's render-JSON endpoint. Every documentation page has a matching
# `<url>.json` under this host; the site itself fetches these to render.
JSON_HOST = "https://developer.apple.com/tutorials/data"
FRAMEWORK = "appkit"
CACHE_DIR = Path("/tmp/appkit-docs-cache")
USER_AGENT = "ccterm-appkit-doc/1.0"


# ── fetching ──────────────────────────────────────────────────────────────


def _cache_path(url_path: str) -> Path:
    # url_path is a doc url like "/documentation/appkit/nsstackview/orientation".
    # Flatten to a single filename so the cache dir stays flat and predictable.
    key = url_path.strip("/").replace("/", "__")
    return CACHE_DIR / f"{key}.json"


def fetch_doc(url_path: str, use_cache: bool) -> dict | None:
    """Fetch a DocC render-JSON document by its doc url path.

    Returns the parsed dict, or None if the symbol page doesn't exist (404) —
    a 404 is a normal "no such symbol / member" answer, not an error.
    """
    cache = _cache_path(url_path)
    if use_cache and cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))

    url = f"{JSON_HOST}{url_path}.json"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise

    if use_cache:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        cache.write_text(raw, encoding="utf-8")
    return json.loads(raw)


# ── DocC content flattening ─────────────────────────────────────────────────


def inline_text(nodes) -> str:
    """Flatten a DocC inline-content array into plain Markdown-ish text.

    DocC mixes plain text with `codeVoice`, symbol `reference`s, emphasis, and
    links inside a single paragraph; walk it recursively so nothing is dropped.
    """
    out: list[str] = []
    for n in nodes or []:
        t = n.get("type")
        if t == "text":
            out.append(n.get("text", ""))
        elif t == "codeVoice":
            out.append(f"`{n.get('code', '')}`")
        elif t == "reference":
            # A cross-reference to another symbol — show its short name.
            out.append(n.get("identifier", "").rstrip("/").split("/")[-1])
        elif t in ("emphasis", "strong"):
            out.append(inline_text(n.get("inlineContent")))
        elif "inlineContent" in n:
            out.append(inline_text(n["inlineContent"]))
    return "".join(out)


def content_blocks(blocks) -> str:
    """Flatten a DocC 'content' block array (paragraphs, headings, code, lists)."""
    lines: list[str] = []
    for blk in blocks or []:
        bt = blk.get("type")
        if bt == "paragraph":
            txt = inline_text(blk.get("inlineContent"))
            if txt.strip():
                lines.append(txt)
        elif bt == "heading":
            lines.append(f"\n### {blk.get('text', '')}")
        elif bt == "codeListing":
            code = "\n".join(blk.get("code", []))
            lines.append(f"```\n{code}\n```")
        elif bt == "unorderedList":
            for item in blk.get("items", []):
                lines.append(f"- {content_blocks(item.get('content'))}")
        elif bt == "orderedList":
            for i, item in enumerate(blk.get("items", []), start=1):
                lines.append(f"{i}. {content_blocks(item.get('content'))}")
        elif bt == "aside":
            style = blk.get("style", "note").capitalize()
            body = content_blocks(blk.get("content"))
            lines.append(f"> **{style}:** {body}")
    return "\n".join(lines)


def declaration(doc: dict) -> str:
    for sec in doc.get("primaryContentSections", []):
        if sec.get("kind") == "declarations":
            for d in sec.get("declarations", []):
                return "".join(tok.get("text", "") for tok in d.get("tokens", []))
    return ""


def availability(doc: dict) -> str:
    plats = doc.get("metadata", {}).get("platforms") or []
    parts = []
    for p in plats:
        name = p.get("name", "")
        intro = p.get("introducedAt", "")
        # Skip a bare platform with no version — "macOS" alone reads as noise.
        if not intro:
            continue
        tag = f"{name} {intro}".strip()
        if p.get("deprecated"):
            tag += " (deprecated)"
        if tag:
            parts.append(tag)
    return ", ".join(parts)


# ── rendering: class page ────────────────────────────────────────────────────


def signature_of(ref: dict) -> str:
    frags = ref.get("fragments") or ref.get("navigatorTitle") or []
    if frags:
        return "".join(f.get("text", "") for f in frags).strip()
    return ref.get("title", "").strip()


def render_class(doc: dict, symbol: str) -> str:
    out: list[str] = []
    md = doc.get("metadata", {})
    title = md.get("title", symbol)
    kind = (md.get("symbolKind") or doc.get("kind") or "symbol").lower()

    out.append(f"# {title}")
    decl = declaration(doc)
    if decl:
        out.append(f"```swift\n{decl}\n```")
    abstract = inline_text(doc.get("abstract"))
    if abstract:
        out.append(abstract)
    avail = availability(doc)
    if avail:
        out.append(f"*Available: {avail}*")

    # Overview / discussion prose.
    for sec in doc.get("primaryContentSections", []):
        if sec.get("kind") == "content":
            body = content_blocks(sec.get("content"))
            if body.strip():
                out.append(body.strip())

    # Members, grouped under Apple's own topic headings, each with a one-line
    # abstract. This is the "what fields/methods does it have, and what do they
    # mean" answer. Dedupe identifiers that Apple lists under two topics.
    refs = doc.get("references", {})
    topic_sections = doc.get("topicSections", [])
    if topic_sections:
        out.append("\n## Members")
        seen: set[str] = set()
        for section in topic_sections:
            title = section.get("title", "")
            rows: list[str] = []
            for ident in section.get("identifiers", []):
                if ident in seen:
                    continue
                seen.add(ident)
                ref = refs.get(ident, {})
                if ref.get("kind") != "symbol":
                    continue
                sig = signature_of(ref)
                if not sig:
                    continue
                abstract = inline_text(ref.get("abstract"))
                if abstract:
                    rows.append(f"- `{sig}`\n    {abstract}")
                else:
                    rows.append(f"- `{sig}`")
            if rows:
                out.append(f"\n### {title}")
                out.extend(rows)

    out.append(
        f"\n---\nFor a member's full docs (parameters, discussion), run: "
        f"`make appkit-doc SYMBOL={symbol}.<member>`"
    )
    return "\n\n".join(out)


# ── rendering: member page ───────────────────────────────────────────────────


def render_member(doc: dict, symbol: str, member: str) -> str:
    out: list[str] = []
    md = doc.get("metadata", {})
    title = md.get("title", member)

    out.append(f"# {symbol}.{title}")
    decl = declaration(doc)
    if decl:
        out.append(f"```swift\n{decl}\n```")
    abstract = inline_text(doc.get("abstract"))
    if abstract:
        out.append(abstract)
    avail = availability(doc)
    if avail:
        out.append(f"*Available: {avail}*")

    for sec in doc.get("primaryContentSections", []):
        kind = sec.get("kind")
        if kind == "parameters":
            params = sec.get("parameters", [])
            if params:
                rows = [
                    f"- `{p.get('name', '')}` — {content_blocks(p.get('content')).strip()}"
                    for p in params
                ]
                out.append("## Parameters\n" + "\n".join(rows))
        elif kind == "content":
            body = content_blocks(sec.get("content"))
            if body.strip():
                out.append(body.strip())

    # See Also — related members, so the reader can pivot without a class dump.
    refs = doc.get("references", {})
    see: list[str] = []
    for sec in doc.get("seeAlsoSections", []):
        for ident in sec.get("identifiers", []):
            ref = refs.get(ident, {})
            sig = signature_of(ref)
            if sig:
                see.append(f"- `{sig}`")
    if see:
        out.append("## See Also\n" + "\n".join(see[:12]))

    return "\n\n".join(out)


# ── member lookup ────────────────────────────────────────────────────────────


def find_member_url(class_doc: dict, symbol: str, member: str, use_cache: bool) -> str | None:
    """Resolve a member name to its doc url.

    First path: match against the class page's `references[ident].url`. We use
    Apple's own url rather than hand-building it — it's already correctly
    lowercased and symbol-encoded (e.g. `setcustomspacing(_:after:)`).

    Fallback: large classes (NSView, NSResponder) split their members into
    separate API-collection pages, so the member won't appear in the class
    page's references at all. In that case the member page still exists at the
    obvious `<class>/<member>` path — probe a few encodings directly. The URL
    encoding is verified: all-lowercase, argument signature kept verbatim.
    """
    refs = class_doc.get("references", {})
    want = member.lower()
    candidates: list[tuple[str, str]] = []
    for ident, ref in refs.items():
        if ref.get("kind") != "symbol" or not ref.get("url"):
            continue
        last = ref["url"].rstrip("/").split("/")[-1]
        # Strip the argument signature so `orientation`, `addSubview`,
        # `setCustomSpacing` all match regardless of `(_:after:)` suffix.
        base = last.split("(", 1)[0]
        if last == want or base == want:
            candidates.append((last, ref["url"]))
    if candidates:
        # Prefer an exact full-name match (incl. signature) over a base match.
        for last, url in candidates:
            if last == want:
                return url
        return candidates[0][1]

    # Fallback probe for members hidden behind API-collection pages.
    base = f"/documentation/{FRAMEWORK}/{symbol.lower()}/{want}"
    for guess in (base, f"{base}()", f"{base}(_:)"):
        if want.endswith(")"):  # user already gave a full signature
            guess = base
        if fetch_doc(guess, use_cache) is not None:
            return guess
        if want.endswith(")"):
            break
    return None


# ── main ─────────────────────────────────────────────────────────────────────


def class_url(symbol: str) -> str:
    return f"/documentation/{FRAMEWORK}/{symbol.lower()}"


def run(query: str, use_cache: bool) -> int:
    if "." in query:
        symbol, member = query.split(".", 1)
    else:
        symbol, member = query, None

    class_doc = fetch_doc(class_url(symbol), use_cache)
    if class_doc is None:
        print(
            f"No AppKit symbol named '{symbol}'. Check spelling/capitalization "
            f"(e.g. NSStackView, NSViewController).",
            file=sys.stderr,
        )
        return 1

    if member is None:
        print(render_class(class_doc, class_doc.get("metadata", {}).get("title", symbol)))
        return 0

    url_path = find_member_url(class_doc, symbol, member, use_cache)
    if url_path is None:
        print(
            f"'{symbol}' has no member '{member}'. Run `make appkit-doc "
            f"SYMBOL={symbol}` to see its members.",
            file=sys.stderr,
        )
        return 1

    member_doc = fetch_doc(url_path, use_cache)
    if member_doc is None:
        print(f"Could not fetch member page: {url_path}", file=sys.stderr)
        return 1
    print(render_member(member_doc, class_doc.get("metadata", {}).get("title", symbol), member))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Look up an AppKit symbol from Apple's official documentation.",
    )
    ap.add_argument(
        "query",
        help="A class (NSStackView) or class.member (NSStackView.orientation).",
    )
    ap.add_argument(
        "--no-cache", action="store_true", help="bypass the /tmp response cache"
    )
    args = ap.parse_args()
    return run(args.query, use_cache=not args.no_cache)


if __name__ == "__main__":
    sys.exit(main())
