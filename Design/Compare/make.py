#!/usr/bin/env python3
# README の「広さの比べ図」を作る（SVG → rsvg-convert で PNG）。
# 使い方: python3 Design/Compare/make.py  → docs/images/compare-*-{ja,en}.png
import os, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "docs", "images")

FONT = "Hiragino Sans, Helvetica Neue, sans-serif"
W = 1100          # 図の幅（PNG はこの 2 倍で書き出す）
PAD = 40
INNER = W - PAD * 2

TEXT = {
    "external": {
        "ja": ("フルHD のモニター（1920 × 1080）", [
            (1920, 1080, "そのまま：1920 × 1080", False),
            (2560, 1440, "Mitame：2560 × 1440", True)],
            "同じモニターで、作業できる広さが約 1.8 倍"),
        "en": ("A Full HD monitor (1920 × 1080)", [
            (1920, 1080, "As is: 1920 × 1080", False),
            (2560, 1440, "Mitame: 2560 × 1440", True)],
            "About 1.8× more room on the same monitor"),
    },
    "builtin": {
        "ja": ("13 インチの MacBook Air（画面は 2560 × 1600）", [
            (1440, 900, "デフォルト：1440 × 900", False),
            (1680, 1050, "スペースを拡大（macOS の上限）：1680 × 1050", False),
            (1920, 1200, "Mitame：1920 × 1200", True)],
            "macOS の上限より約 1.3 倍、デフォルトより約 1.8 倍広い"),
        "en": ("13-inch MacBook Air (2560 × 1600 panel)", [
            (1440, 900, "Default: 1440 × 900", False),
            (1680, 1050, "More Space (macOS maximum): 1680 × 1050", False),
            (1920, 1200, "Mitame: 1920 × 1200", True)],
            "About 1.3× more room than the macOS maximum, 1.8× more than the default"),
    },
}

def svg(kind, lang):
    title, rects, caption = TEXT[kind][lang]
    maxw = max(r[0] for r in rects)
    s = INNER / maxw
    top = PAD + 56
    boxh = max(r[1] for r in rects) * s
    H = int(top + boxh + 80)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
           f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="18" fill="#f6f8fa" stroke="#d0d7de" stroke-width="2"/>',
           f'<text x="{PAD}" y="{PAD+20}" font-family="{FONT}" font-size="24" font-weight="600" fill="#1f2328">{title}</text>']
    # 大きいものから描いて、小さいものを左上に重ねる
    for w, h, label, mitame in sorted(rects, key=lambda r: -r[0]):
        rw, rh = w * s, h * s
        fill = "#ddebff" if mitame else "#ffffff"
        stroke = "#0969da" if mitame else "#8c959f"
        dash = '' if mitame else ' stroke-dasharray="8 6"'
        out.append(f'<rect x="{PAD}" y="{top}" width="{rw:.1f}" height="{rh:.1f}" rx="6" fill="{fill}" fill-opacity="{1 if mitame else 0.85}" stroke="{stroke}" stroke-width="3"{dash}/>')
        color = "#0969da" if mitame else "#57606a"
        weight = "700" if mitame else "500"
        out.append(f'<text x="{PAD + rw - 14:.1f}" y="{top + rh - 16:.1f}" text-anchor="end" font-family="{FONT}" font-size="22" font-weight="{weight}" fill="{color}">{label}</text>')
    out.append(f'<text x="{W/2}" y="{top + boxh + 50:.1f}" text-anchor="middle" font-family="{FONT}" font-size="26" font-weight="700" fill="#1f2328">{caption}</text>')
    out.append('</svg>')
    return "\n".join(out)

for kind in TEXT:
    for lang in ("ja", "en"):
        base = os.path.join(HERE, f"compare-{kind}-{lang}")
        open(base + ".svg", "w").write(svg(kind, lang))
        png = os.path.join(OUT, f"compare-{kind}-{lang}.png")
        subprocess.run(["rsvg-convert", "-z", "2", "-o", png, base + ".svg"], check=True)
        print(png)
