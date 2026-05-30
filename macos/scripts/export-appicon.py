#!/usr/bin/env python3
"""Export the macOS app icon from design/icon/icon-capsule.html.

The HTML is the single source of truth for the icon. This script does NOT
reimplement any geometry, colour or size — it drives the HTML itself in
headless Chrome (the page exposes an `?export=<px>` mode that renders only
the finished `#iconArt` onto a transparent canvas) and screenshots each
macOS size into the asset catalogue. Edit the HTML / its styles and re-run
`make appicon`; the exported PNGs follow automatically.

Requires: Google Chrome (or Chromium) and `sips` (built into macOS).
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HTML = REPO / "design" / "icon" / "icon-capsule.html"
ICONSET = REPO / "macos" / "ccterm" / "Assets.xcassets" / "AppIcon.appiconset"

# The standard macOS app-icon ladder: (size, scale, pixels = size * scale).
ENTRIES = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if Path(c).exists():
            return c
    for name in ("google-chrome", "chromium", "chromium-browser"):
        found = shutil.which(name)
        if found:
            return found
    sys.exit("error: Chrome/Chromium not found — needed to rasterize the icon.")


def filename(size: str, scale: str) -> str:
    return f"icon_{size}.png" if scale == "1x" else f"icon_{size}@{scale}.png"


def png_width(path: Path) -> int:
    out = subprocess.run(
        ["sips", "-g", "pixelWidth", str(path)], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        if "pixelWidth" in line:
            return int(line.split(":")[1])
    return -1


def render(chrome: str, px: int, dest: Path, master: Path | None) -> None:
    """Render the icon at `px` natively; fall back to downscaling the master
    if the headless window got clamped (defensive — native works to 16px)."""
    url = f"{HTML.as_uri()}?export={px}"
    subprocess.run(
        [
            chrome, "--headless", "--disable-gpu", "--no-sandbox",
            "--hide-scrollbars", "--force-device-scale-factor=1",
            "--default-background-color=00000000",
            f"--window-size={px},{px}", f"--screenshot={dest}", url,
        ],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if png_width(dest) != px:
        if master is None or not master.exists():
            sys.exit(f"error: {px}px render came out wrong-sized and no master to downscale.")
        subprocess.run(
            ["sips", "-z", str(px), str(px), str(master), "--out", str(dest)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def main() -> None:
    if not HTML.exists():
        sys.exit(f"error: source HTML not found: {HTML}")
    ICONSET.mkdir(parents=True, exist_ok=True)
    chrome = find_chrome()
    print(f"source : {HTML.relative_to(REPO)}")
    print(f"target : {ICONSET.relative_to(REPO)}")
    print(f"chrome : {chrome}")

    for stale in ICONSET.glob("icon_*.png"):
        stale.unlink()

    # Render each distinct pixel size once (largest first → master for fallback).
    rendered: dict[int, Path] = {}
    master: Path | None = None
    for px in sorted({px for _, _, px in ENTRIES}, reverse=True):
        tmp = ICONSET / f"_render_{px}.png"
        render(chrome, px, tmp, master)
        master = master or tmp
        rendered[px] = tmp
        print(f"  rendered {px}×{px}")

    images = []
    for size, scale, px in ENTRIES:
        out = ICONSET / filename(size, scale)
        shutil.copyfile(rendered[px], out)
        images.append({"filename": out.name, "idiom": "mac", "scale": scale, "size": size})

    for tmp in set(rendered.values()):
        tmp.unlink(missing_ok=True)

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {len(images)} PNGs + Contents.json")


if __name__ == "__main__":
    main()
