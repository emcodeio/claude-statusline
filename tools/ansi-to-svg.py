#!/usr/bin/env python3
"""Render ANSI-coloured terminal output (on stdin) as a standalone SVG.

Built for capturing the statusline without needing a real screenshot: the
output is text, so it diffs and versions cleanly, and stays crisp at any zoom.

    sh statusline-command.sh < tools/demo-payload.json \
        | python3 tools/ansi-to-svg.py > screenshot.svg

Handles the subset of SGR this statusline emits: 24-bit foreground
(38;2;R;G;B), dim (2), and reset (0). Anything else is ignored rather than
guessed at. Standard library only — no dependencies.
"""

import html
import re
import sys

# One cell per character. 8.4 x 20 at 14px matches a typical terminal's aspect
# ratio closely enough that the bar glyphs still read as contiguous.
CELL_W, CELL_H, FONT_SIZE = 8.4, 20.0, 14
PAD_X, PAD_Y = 14.0, 12.0
BG, FG_DEFAULT = "#1d1f21", "#c5c8c6"
DIM_OPACITY = 0.55
# Double-width glyphs used by the statusline. Kept explicit rather than pulling
# in a wcwidth dependency for a single emoji.
WIDE = {"\U0001f911"}

SGR = re.compile(r"\x1b\[([0-9;]*)m")


class Style:
    __slots__ = ("color", "dim")

    def __init__(self):
        self.color, self.dim = None, False

    def copy(self):
        s = Style()
        s.color, s.dim = self.color, self.dim
        return s


def apply_sgr(style, params):
    """Mutate `style` per one SGR escape's parameter list."""
    codes = [int(p) if p else 0 for p in params.split(";")] or [0]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            style.color, style.dim = None, False
        elif c == 2:
            style.dim = True
        elif c == 22:
            style.dim = False
        elif c == 39:
            style.color = None
        elif c == 38 and i + 4 < len(codes) and codes[i + 1] == 2:
            style.color = "#%02x%02x%02x" % tuple(codes[i + 2 : i + 5])
            i += 4
        elif 30 <= c <= 37:  # basic ANSI, approximated
            style.color = [
                "#000000", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            ][c - 30]
        i += 1
    return style


def parse(line):
    """Split one line into (text, Style) runs, dropping the escapes."""
    runs, style, pos = [], Style(), 0
    for m in SGR.finditer(line):
        if m.start() > pos:
            runs.append((line[pos : m.start()], style.copy()))
        style = apply_sgr(style, m.group(1))
        pos = m.end()
    if pos < len(line):
        runs.append((line[pos:], style.copy()))
    return runs


def cells(text):
    return sum(2 if ch in WIDE else 1 for ch in text)


def main():
    lines = sys.stdin.read().rstrip("\n").split("\n")
    rows = [parse(l) for l in lines]
    width = max((sum(cells(t) for t, _ in r) for r in rows), default=0)

    w = PAD_X * 2 + width * CELL_W
    h = PAD_Y * 2 + len(rows) * CELL_H
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {w:.2f} {h:.2f}" role="img" '
        f'aria-label="Claude Code statusline">',
        f'<rect width="{w:.2f}" height="{h:.2f}" rx="6" fill="{BG}"/>',
        f'<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'
        f'&quot;DejaVu Sans Mono&quot;,monospace" font-size="{FONT_SIZE}" '
        f'xml:space="preserve">',
    ]
    for i, runs in enumerate(rows):
        y = PAD_Y + (i + 1) * CELL_H - CELL_H * 0.28
        out.append(f'<text y="{y:.2f}" fill="{FG_DEFAULT}">')
        col = 0
        for text, st in runs:
            if not text:
                continue
            attrs = f'x="{PAD_X + col * CELL_W:.2f}"'
            if st.color:
                attrs += f' fill="{st.color}"'
            if st.dim:
                attrs += f' opacity="{DIM_OPACITY}"'
            out.append(f"<tspan {attrs}>{html.escape(text)}</tspan>")
            col += cells(text)
        out.append("</text>")
    out += ["</g>", "</svg>"]
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
