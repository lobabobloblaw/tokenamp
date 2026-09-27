#!/usr/bin/env python3
"""Render the README's screenshots from the real app.

Uses ``Tokenamp --snapshot`` so what ends up in the README is exactly what the
app draws -- offscreen, so it needs no Screen Recording permission.

    python3 scripts/make_screenshots.py

Writes ``docs/images/hero.png`` (one skin's default layout: main, Sessions and
Token Flow stacked),
``docs/images/demo.gif`` (that layout running for a few seconds: the marquee
scrolling, the countdown ticking, the visualiser and the Token Flow field moving;
from ``Tokenamp --snapshot --frames``),
``docs/images/lineup.png`` (that default layout in every skin, side by side),
``docs/images/social.png`` (the 1280x640 GitHub social preview: the icon, a
wordmark set in the skin toolkit's own bitmap face, and two skins' stacks),
``docs/images/flow.png`` (the Token Flow window, one configuration per skin) and
``docs/images/icon.png`` (the app icon, for the README's header).

The demo clock defaults to ``DemoUsageProvider.referenceDate`` rather than to
now, so these images are deterministic: re-running this script over unchanged
art rewrites them byte for byte.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images"
APP = ROOT / "build" / "Tokenamp.app" / "Contents" / "MacOS" / "Tokenamp"

#: order the skins appear in the gallery
SKINS = ["Bulkhead", "Walnut76", "Amethyst", "Bookcloth", "Base"]
HERO = "Bulkhead"
#: the stacks on the social preview card: one dark skin, one light
SOCIAL = ["Bulkhead", "Bookcloth"]
#: one Token Flow configuration per skin for the gallery row -- five geometries, five palettes
FLOW = [("Bulkhead", "scope"), ("Amethyst", "web"), ("Walnut76", "orbit"),
        ("Bookcloth", "strata"), ("Base", "phase")]
SCALE = 2
PAD = 16
BG = (22, 22, 24)

#: demo.gif: 52 minutes before the demo's session window resets, so the time display counts
#: down in MM:SS and ticks every second (with an hour or more left it reads HH:MM and would stand
#: still for the whole loop), in the middle of a burst of work, so the live visualiser bars move
ANIM_AT = 1_789_933_480
ANIM_SECONDS = 6
#: 25 fps is the marquee's own speed, one skin pixel a frame, and a whole number of GIF
#: centiseconds (4) per frame
ANIM_FPS = 25
#: the Token Flow configuration it shows: scope, like hero.png and the app's default
ANIM_FIELD = "scope"


def snapshot(skin: str, into: Path, scale: int = SCALE) -> dict[str, Image.Image]:
    into.mkdir(parents=True, exist_ok=True)
    wsz = ROOT / "skins" / "dist" / f"{skin}.wsz"
    if not wsz.is_file():
        sys.exit(f"missing {wsz} -- run: python3 skins/build.py --all")
    subprocess.run([str(APP), "--snapshot", str(into), "--demo",
                    "--skin", str(wsz), "--scale", str(scale)],
                   check=True, capture_output=True)
    return {p.stem: Image.open(p).convert("RGB") for p in into.glob("*.png")}


def animate(skin: str, into: Path) -> list[Path]:
    """``Tokenamp --snapshot --frames``: the default layout running, one PNG per frame."""
    into.mkdir(parents=True, exist_ok=True)
    wsz = ROOT / "skins" / "dist" / f"{skin}.wsz"
    if not wsz.is_file():
        sys.exit(f"missing {wsz} -- run: python3 skins/build.py --all")
    subprocess.run([str(APP), "--snapshot", str(into), "--demo", "--skin", str(wsz),
                    "--scale", str(SCALE), "--at", str(ANIM_AT), "--field", ANIM_FIELD,
                    "--frames", str(ANIM_SECONDS * ANIM_FPS), "--fps", str(ANIM_FPS)],
                   check=True, capture_output=True)
    return sorted(into.glob("frame-*.png"))


def write_gif(frames: list[Path], out: Path) -> None:
    """A looping GIF of ``frames``, each padded the way the stills are.

    Every frame is mapped onto one shared palette, without dithering, so a pixel keeps the
    same colour from frame to frame and the art stays pixel-crisp: dither would crawl, and
    per-frame palettes would flicker. The palette is an octree over a sample of the frames;
    it holds the skin's art and the phosphor ramp to within a few levels. One entry is left
    free, and Pillow's ``optimize`` uses it to make each frame's unchanged pixels transparent
    over the last, so a frame costs only what moved.
    """
    def framed(path: Path) -> Image.Image:
        return stack([Image.open(path).convert("RGB")], gap=0)

    sample = [framed(p) for p in frames[::max(1, len(frames) // 15)]]
    sheet = Image.new("RGB", (sample[0].width, sample[0].height * len(sample)))
    for i, im in enumerate(sample):
        sheet.paste(im, (0, i * im.height))
    palette = sheet.quantize(colors=255, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    indexed = [framed(p).quantize(palette=palette, dither=Image.Dither.NONE) for p in frames]
    indexed[0].save(out, save_all=True, append_images=indexed[1:], duration=1000 // ANIM_FPS,
                    loop=0, optimize=True, disposal=1)


def stack(images: list[Image.Image], gap: int) -> Image.Image:
    w = max(im.width for im in images) + PAD * 2
    h = sum(im.height for im in images) + gap * (len(images) - 1) + PAD * 2
    out = Image.new("RGB", (w, h), BG)
    y = PAD
    for im in images:
        out.paste(im, ((w - im.width) // 2, y))
        y += im.height + gap
    return out


def grid(images: list[Image.Image], per_row: int, gap: int) -> Image.Image:
    rows = [images[i:i + per_row] for i in range(0, len(images), per_row)]
    row_w = [sum(im.width for im in r) + gap * (len(r) - 1) for r in rows]
    w = max(row_w) + PAD * 2
    h = sum(max(im.height for im in r) for r in rows) + gap * (len(rows) - 1) + PAD * 2
    out = Image.new("RGB", (w, h), BG)
    y = PAD
    for r, width in zip(rows, row_w):
        x = (w - width) // 2
        for im in r:
            out.paste(im, (x, y))
            x += im.width + gap
        y += max(im.height for im in r) + gap
    return out


def row(images: list[Image.Image], gap: int) -> Image.Image:
    """Side by side, tops aligned."""
    return grid(images, per_row=len(images), gap=gap)


def default_stack(shots: dict[str, Image.Image]) -> Image.Image:
    """The layout the app opens with: main, Sessions, Token Flow, flush."""
    return stack([shots["main"], shots["playlist"], shots["field-scope"]], gap=0)


def pixel_text(text: str, font, scale: int, ink: tuple[int, int, int]) -> Image.Image:
    """``text`` in one of the skin toolkit's bitmap faces, blown up nearest-neighbour, on
    transparent ground - so the social card's type is pixel art like everything else."""
    sys.path.insert(0, str(ROOT / "skins"))
    from skinkit.fonts import text_mask
    mask = text_mask(text, font)
    h, w = mask.shape
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y in range(h):
        for x in range(w):
            if mask[y, x]:
                px[x, y] = ink + (255,)
    return im.resize((w * scale, h * scale), Image.NEAREST)


def social_card(stacks: list[Image.Image], icon: Image.Image | None) -> Image.Image:
    """1280x640, GitHub's social preview size: icon and wordmark on the left, stacks on the right."""
    sys.path.insert(0, str(ROOT / "skins"))
    from skinkit.fonts import FONT_5x6, MICRO_4x5
    W, H = 1280, 640
    card = Image.new("RGB", (W, H), BG)
    gap = 20
    shelf_w = sum(s.width for s in stacks) + gap * (len(stacks) - 1)
    x = W - 48 - shelf_w
    for s in stacks:
        card.paste(s, (x, (H - s.height) // 2))
        x += s.width + gap
    left_w = W - 48 - shelf_w
    room = left_w - 96

    def fitted(text: str, font, largest: int, ink: tuple[int, int, int]) -> Image.Image:
        """The largest whole-pixel scale, up to ``largest``, at which ``text`` fits the column."""
        one = pixel_text(text, font, 1, ink)
        scale = max(1, min(largest, room // one.width))
        return one.resize((one.width * scale, one.height * scale), Image.NEAREST)

    title = fitted("TOKENAMP", FONT_5x6, 10, (240, 232, 214))
    subtitle = ("YOUR CLAUDE USAGE,", "AS A WINAMP 2.X PLAYER")
    sub_scale = max(1, min(5, room // max(pixel_text(t, MICRO_4x5, 1, (0, 0, 0)).width for t in subtitle)))
    lines = [pixel_text(t, MICRO_4x5, sub_scale, (160, 156, 148)) for t in subtitle]
    blocks: list[Image.Image] = []
    if icon is not None:
        blocks.append(icon.resize((200, 200), Image.LANCZOS))
    blocks += [title] + lines
    spacing = [28, 22, 10]
    total = sum(b.height for b in blocks) + sum(spacing[:len(blocks) - 1])
    y = (H - total) // 2
    for i, b in enumerate(blocks):
        card.paste(b, ((left_w - b.width) // 2, y), b if b.mode == "RGBA" else None)
        y += b.height + (spacing[i] if i < len(spacing) else 0)
    return card


def export_icon(tmp: Path) -> None:
    """Pull the 512 px face out of the tracked .icns for the README header."""
    icns = ROOT / "assets" / "Tokenamp.icns"
    if not icns.is_file():
        print(f"skipping icon: no {icns}")
        return
    iconset = tmp / "icon.iconset"
    subprocess.run(["iconutil", "-c", "iconset", str(icns), "-o", str(iconset)],
                   check=True, capture_output=True)
    src = iconset / "icon_256x256@2x.png"
    Image.open(src).convert("RGBA").save(OUT / "icon.png")
    print(f"wrote {OUT / 'icon.png'}")


def main() -> None:
    if not APP.is_file():
        sys.exit(f"missing {APP} -- run: scripts/build_app.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        export_icon(tmp)
        shots = {s: snapshot(s, tmp / s) for s in SKINS}

        hero = shots[HERO]
        # The default layout the app opens with: main, Sessions, Token Flow, flush.
        stack([hero["main"], hero["playlist"], hero["field-scope"]], gap=0).save(OUT / "hero.png")
        print(f"wrote {OUT / 'hero.png'}")

        write_gif(animate(HERO, tmp / f"{HERO}-frames"), OUT / "demo.gif")
        print(f"wrote {OUT / 'demo.gif'}")

        row([default_stack(shots[s]) for s in SKINS], gap=PAD * 2).save(OUT / "lineup.png")
        print(f"wrote {OUT / 'lineup.png'}")

        grid([shots[skin][f"field-{mode}"] for skin, mode in FLOW],
             per_row=3, gap=PAD).save(OUT / "flow.png")
        print(f"wrote {OUT / 'flow.png'}")

        small = {s: snapshot(s, tmp / f"{s}-1x", scale=1) for s in SOCIAL}
        icon = Image.open(OUT / "icon.png").convert("RGBA") if (OUT / "icon.png").is_file() else None
        social_card([default_stack(small[s]) for s in SOCIAL], icon).save(OUT / "social.png")
        print(f"wrote {OUT / 'social.png'}")


if __name__ == "__main__":
    main()
