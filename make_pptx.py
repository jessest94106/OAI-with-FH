"""
OAI O-RAN 7.2 Split — END-TO-END DEMO deck (.pptx)
Framing: a working single-host emulation; what we can EVALUATE on it and what we FIND.
All numbers from the actual sweep logs under logs/iq_width_sweep/.
Layout is laid out on an explicit grid so nothing overlaps.
"""

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
import math

# ── palette ──────────────────────────────────────────────────────────────
DARK   = RGBColor(0x1F, 0x39, 0x64)
BLUE   = RGBColor(0x2E, 0x75, 0xB6)
LBLUE  = RGBColor(0xBD, 0xD7, 0xEE)
GREEN  = RGBColor(0x37, 0x86, 0x44)
RED    = RGBColor(0xC0, 0x00, 0x00)
ORANGE = RGBColor(0xC5, 0x5A, 0x11)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
BLACK  = RGBColor(0x20, 0x20, 0x20)
GRAY   = RGBColor(0xF2, 0xF2, 0xF2)
MGRAY  = RGBColor(0xD9, 0xD9, 0xD9)
GREENBG= RGBColor(0xE2, 0xEF, 0xDA)
ORNGBG = RGBColor(0xFC, 0xE4, 0xD6)
REDBG  = RGBColor(0xF8, 0xCB, 0xCB)
TANBG  = RGBColor(0xFF, 0xF2, 0xCC)

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]

# ── primitives ──────────────────────────────────────────────────────────
def rect(sl, x, y, w, h, fill=None, line=None, line_w=0.75):
    s = sl.shapes.add_shape(1, x, y, w, h)
    s.shadow.inherit = False
    if fill:
        s.fill.solid(); s.fill.fore_color.rgb = fill
    else:
        s.fill.background()
    if line:
        s.line.color.rgb = line; s.line.width = Pt(line_w)
    else:
        s.line.fill.background()
    return s

def text(sl, t, x, y, w, h, size=14, bold=False, italic=False,
         color=BLACK, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, wrap=True):
    tb = sl.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame; tf.word_wrap = wrap
    tf.vertical_anchor = anchor
    tf.margin_left = Pt(2); tf.margin_right = Pt(2)
    tf.margin_top = Pt(1); tf.margin_bottom = Pt(1)
    lines = t.split("\n")
    for i, ln in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        r = p.add_run(); r.text = ln
        r.font.size = Pt(size); r.font.bold = bold; r.font.italic = italic
        r.font.color.rgb = color; r.font.name = "Calibri"
    return tb

def title_bar(sl, t, sub=None):
    rect(sl, 0, 0, prs.slide_width, Inches(1.1), fill=DARK)
    text(sl, t, Inches(0.35), Inches(0.1), Inches(12.6), Inches(0.62),
         size=27, bold=True, color=WHITE, anchor=MSO_ANCHOR.MIDDLE)
    if sub:
        text(sl, sub, Inches(0.35), Inches(0.72), Inches(12.6), Inches(0.34),
             size=13, color=LBLUE)

def chip(sl, t, x, y, w, h=Inches(0.3), color=BLUE):
    rect(sl, x, y, w, h, fill=color)
    text(sl, t, x, y, w, h, size=11, bold=True, color=WHITE,
         align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

def callout(sl, t, x, y, w, h, bg=LBLUE, size=12.5, edge=BLUE, color=DARK, bold=False):
    rect(sl, x, y, w, h, fill=bg, line=edge)
    text(sl, t, x + Inches(0.1), y + Inches(0.05), w - Inches(0.2), h - Inches(0.1),
         size=size, color=color, anchor=MSO_ANCHOR.MIDDLE, bold=bold)

def table(sl, headers, rows, x, y, w, col_w, row_h=Inches(0.4),
          header_color=BLUE, font=12, cell_colors=None, header_font=12):
    """Returns bottom-y of the table."""
    cx = x
    for hdr, cw in zip(headers, col_w):
        rect(sl, cx, y, cw, row_h, fill=header_color, line=WHITE)
        text(sl, hdr, cx, y, cw, row_h, size=header_font, bold=True, color=WHITE,
             align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        cx += cw
    for ri, row in enumerate(rows):
        cy = y + row_h * (ri + 1)
        base = LBLUE if ri % 2 else GRAY
        cx = x
        for ci, (cell, cw) in enumerate(zip(row, col_w)):
            bg = base
            if cell_colors and (ri, ci) in cell_colors:
                bg = cell_colors[(ri, ci)]
            rect(sl, cx, cy, cw, row_h, fill=bg, line=MGRAY)
            s = str(cell); tc = BLACK
            if s in ("✓", "✓ works", "works", "stable"): tc = GREEN
            elif "FAIL" in s or s in ("crash", "RU CRASH", "✗"): tc = RED
            text(sl, s, cx, cy, cw, row_h, size=font, color=tc,
                 align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
            cx += cw
    return y + row_h * (len(rows) + 1)

def bar_chart(sl, x, top_y, w, plot_h, data, max_val, bar_color=BLUE,
              fmt="{:.0f}", overlay_line=None, line_max=None, line_label=None,
              ylabel=None):
    """
    Vertical bars. Footprint: value labels [top_y, top_y+0.22],
    bars [top_y+0.25 .. baseline], cat labels [baseline .. +0.28].
    overlay_line: list of values plotted on a secondary 0..line_max scale.
    ylabel: unit string drawn at the top-left of the plot (e.g. "Mbps").
    """
    bars_top = top_y + Inches(0.25)
    baseline = bars_top + plot_h
    n = len(data)
    slot = w / n
    bar_w = min(slot * 0.5, Inches(1.1))
    # baseline axis
    rect(sl, x, baseline, w, Inches(0.02), fill=BLACK)
    if ylabel:
        text(sl, ylabel, x - Inches(0.05), top_y - Inches(0.02), Inches(1.4), Inches(0.22),
             size=10, bold=True, italic=True, color=BLACK, align=PP_ALIGN.LEFT)
    centers = []
    for i, (lbl, val) in enumerate(data):
        bh = plot_h * (val / max_val)
        bx = x + slot * i + (slot - bar_w) / 2
        by = baseline - bh
        rect(sl, bx, by, bar_w, bh, fill=bar_color)
        text(sl, fmt.format(val), bx - Inches(0.15), by - Inches(0.24),
             bar_w + Inches(0.3), Inches(0.22), size=10, bold=True, color=bar_color,
             align=PP_ALIGN.CENTER)
        text(sl, lbl, x + slot * i, baseline + Inches(0.03), slot, Inches(0.26),
             size=11, color=BLACK, align=PP_ALIGN.CENTER)
        centers.append(bx + bar_w / 2)
    if overlay_line:
        pts = []
        for i, v in enumerate(overlay_line):
            ly = baseline - plot_h * (v / line_max)
            pts.append((centers[i], ly))
        for i in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            seg = sl.shapes.add_connector(2, x0, y0, x1, y1)
            seg.line.color.rgb = GREEN; seg.line.width = Pt(2.25)
            seg.shadow.inherit = False
        for (px, py) in pts:
            rect(sl, px - Inches(0.05), py - Inches(0.05), Inches(0.1), Inches(0.1), fill=GREEN)
        if line_label:
            text(sl, line_label, x, top_y - Inches(0.02), w, Inches(0.22),
                 size=10, bold=True, color=GREEN, align=PP_ALIGN.RIGHT)
    return baseline + Inches(0.3)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 1 — TITLE
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
rect(sl, 0, 0, prs.slide_width, prs.slide_height, fill=DARK)
rect(sl, 0, Inches(2.45), prs.slide_width, Inches(2.65), fill=BLUE)
text(sl, "OAI O-RAN 7.2 Split", Inches(0.6), Inches(1.25), Inches(12.1), Inches(0.9),
     size=40, bold=True, color=WHITE, align=PP_ALIGN.CENTER)
text(sl, "A Demo of End-to-End Emulation\nand IQ Compression Evaluation",
     Inches(0.6), Inches(2.55), Inches(12.1), Inches(1.7),
     size=34, bold=True, color=WHITE, align=PP_ALIGN.CENTER)
text(sl, "Single-host DU + O-RU + UE over real DPDK fronthaul — a platform to observe system trade-offs:\n"
         "UL throughput · fronthaul load · latency · PRB / bandwidth · SNR · mobility",
     Inches(0.8), Inches(5.2), Inches(11.7), Inches(0.8),
     size=15, color=LBLUE, align=PP_ALIGN.CENTER)
text(sl, "Jesse   ·   2026", Inches(0.8), Inches(6.85), Inches(11.7), Inches(0.4),
     size=13, color=MGRAY, align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 2 — SYSTEM OVERVIEW IN THE DEMO   (user title kept)
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "System Overview in the Demo",
          "One host runs the whole 5G chain — real DPDK fronthaul, emulated radio")

# chain of 3 main boxes
bw, bh, by = Inches(2.4), Inches(0.88), Inches(1.35)
xs = [Inches(0.5), Inches(4.7), Inches(8.9)]
mains = [("DU\nnr-softmodem (PHY/MAC)", DARK, "24 PRB · µ1 30 kHz · n77 4.05 GHz"),
         ("O-RU\nnr-oru (RU PHY)", BLUE,  "O-RAN 7.2 split · IQ compression"),
         ("UE\nnr-uesoftmodem", DARK,     "1 UE · oaitun_ue1 · 10.0.0.x")]
for (lab, c, detail), x in zip(mains, xs):
    rect(sl, x, by, bw, bh, fill=c)
    text(sl, lab, x, by, bw, bh, size=13.5, bold=True, color=WHITE,
         align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    text(sl, detail, x, by + bh + Inches(0.02), bw, Inches(0.28),
         size=9.5, italic=True, color=DARK, align=PP_ALIGN.CENTER)

# connectors with richer labels
def conn(x, top, bot):
    rect(sl, x, by + Inches(0.40), Inches(1.8), Inches(0.05), fill=BLUE)
    text(sl, top, x, by + Inches(0.00), Inches(1.8), Inches(0.24),
         size=11, bold=True, color=DARK, align=PP_ALIGN.CENTER)
    text(sl, bot, x, by + Inches(0.46), Inches(1.8), Inches(0.42),
         size=9, italic=True, color=BLUE, align=PP_ALIGN.CENTER)
conn(xs[0] + bw, "O-RAN 7.2 FH", "eCPRI · DPDK SR-IOV\nVF0/1↑  VF2/3↓ · VLAN 3/4")
conn(xs[1] + bw, "vrtsim air", "shared memory · IQ\nTDL fading · AGC SNR")

# 5GC + iperf under DU / UE
text(sl, "↕  NGAP / GTP-U", xs[0], Inches(2.56), bw, Inches(0.28),
     size=10, color=DARK, align=PP_ALIGN.CENTER)
rect(sl, xs[0], Inches(2.86), bw, Inches(0.82), fill=RGBColor(0x10,0x50,0x40))
text(sl, "OAI 5GC (docker)\nAMF · SMF · UPF · NRF", xs[0], Inches(2.86), bw, Inches(0.82),
     size=11, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
text(sl, "↕  iperf3 client (UE) -c 10.0.0.1", xs[2], Inches(2.56), bw, Inches(0.28),
     size=10, color=DARK, align=PP_ALIGN.CENTER)
rect(sl, xs[2], Inches(2.86), bw, Inches(0.82), fill=RGBColor(0x10,0x40,0x55))
text(sl, "UL received here\n(iperf3 server @ 5GC/UPF)", xs[2], Inches(2.86), bw, Inches(0.82),
     size=10.5, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# middle annotation under O-RU
text(sl, "real-time channel\nemulation (CPU)", xs[1], Inches(2.86), bw, Inches(0.82),
     size=10, italic=True, color=BLUE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# specs strip
rect(sl, Inches(0.5), Inches(3.82), Inches(12.3), Inches(0.32), fill=GRAY, line=MGRAY)
text(sl, "NIC: Intel X710 (i40e) · 5 SR-IOV VFs · VF↔VF loopback (embedded VEB switch, no cable)   "
         "|   Fronthaul = real eCPRI packets over DPDK   |   Air = vrtsim shared-memory IQ",
     Inches(0.5), Inches(3.82), Inches(12.3), Inches(0.32),
     size=10.5, color=DARK, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# what we can sweep
chip(sl, "What we can sweep / evaluate", Inches(0.5), Inches(4.22), Inches(12.3))
table(sl,
    ["Parameter", "What it controls in the demo"],
    [["IQ width  (8 / 9 / 12 / 16)", "Fronthaul byte load (IQ compression)"],
     ["RX target SNR (dB)",          "Radio link quality (time-domain AGC)"],
     ["Antennas  (1×1 → 4×4)",       "MIMO layers & fronthaul load multiplier"],
     ["FH delivery window (µs)",     "Fronthaul timing / latency budget"],
     ["Mobility (channel time-var.)", "Time-varying fading"],
     ["Bandwidth (PRB)",             "Cell bandwidth, 10 – 100 MHz"]],
    x=Inches(0.5), y=Inches(4.50), w=Inches(12.3),
    col_w=[Inches(4.3), Inches(8.0)], row_h=Inches(0.31), font=12)

callout(sl,
    "UL throughput = traffic RECEIVED at the 5GC (UPF), where the iperf3 server runs — the real goodput, "
    "not the UE's send rate (which over-reports, since the UE drops excess at the TUN).",
    Inches(0.5), Inches(6.74), Inches(12.3), Inches(0.4), bg=TANBG, edge=ORANGE, size=11)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 3 — BASELINE   (user title kept)
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Baseline: 10 MHz Radio Bandwidth",
          "The reference operating point — each later slide varies ONE knob and watches the trend")

chip(sl, "Measured — 1×1, 24 PRB µ1, ideal channel  (UL received at 5GC/UPF, iperf3 UDP)",
     Inches(0.4), Inches(1.3), Inches(12.5))
table(sl,
    ["Config", "IQ", "FH total Mbps", "UL Mbps", "Jitter ms", "UL loss"],
    [["1×1 ideal", "9",  "150.8", "4.995", "1.83", "0.00%"],
     ["1×1 ideal", "9",  "150.8", "5.004", "—",    "—"],
     ["1×1 ideal", "16", "254.0", "5.006", "—",    "—"]],
    x=Inches(0.4), y=Inches(1.65), w=Inches(12.5),
    col_w=[Inches(2.6), Inches(1.4), Inches(2.7), Inches(2.4), Inches(1.9), Inches(1.5)],
    row_h=Inches(0.45), font=14)

facts = [("UL throughput", "~5.0 Mbps"), ("UL loss", "0.00 %"),
         ("Jitter", "~1.8 ms"), ("UL symbols", "100 %"),
         ("FH load", "150 / 254\nMbps (iq9/16)")]
fx = Inches(0.4); fw = Inches(2.4); gap = Inches(0.13)
for i, (lab, val) in enumerate(facts):
    x = fx + i * (fw + gap)
    rect(sl, x, Inches(3.5), fw, Inches(1.25), fill=BLUE)
    text(sl, lab, x, Inches(3.58), fw, Inches(0.35), size=12, color=LBLUE, align=PP_ALIGN.CENTER)
    text(sl, val, x, Inches(3.95), fw, Inches(0.75), size=17, bold=True, color=WHITE,
         align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

callout(sl,
    "This is the reference point.  From here, each evaluation changes one parameter — IQ compression, SNR, "
    "MIMO, fronthaul latency, mobility, bandwidth — and we read the TREND in UL throughput, fronthaul load, "
    "latency and resource use.",
    Inches(0.4), Inches(5.05), Inches(12.5), Inches(0.95), bg=GREENBG, edge=GREEN, size=13.5)
callout(sl,
    "The point of the demo is not 'it works' — it is that one host lets us sweep these knobs and SEE the trade-offs.",
    Inches(0.4), Inches(6.15), Inches(12.5), Inches(0.5), bg=LBLUE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 4 — EVAL 1: IQ COMPRESSION
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 1 — IQ Compression vs Fronthaul Load",
          "Sweep IQ width 8→16 in one bringup  ·  what does compression buy us?")

chip(sl, "Measured (single sweep, 1×1 ideal channel)", Inches(0.4), Inches(1.3), Inches(7.4))
table(sl,
    ["IQ width", "FH total Mbps", "UL Mbps", "UL loss"],
    [["8  (most compressed)", "135.2", "4.999", "0.00%"],
     ["9  (BFP default)",     "150.8", "4.999", "0.00%"],
     ["12",                   "197.4", "5.001", "0.00%"],
     ["16 (uncompressed)",    "254.0", "5.001", "0.00%"]],
    x=Inches(0.4), y=Inches(1.65), w=Inches(7.4),
    col_w=[Inches(2.7), Inches(1.9), Inches(1.5), Inches(1.3)],
    row_h=Inches(0.46), font=13)

# bar chart (left-lower)
chip(sl, "Fronthaul load (bars) vs UL throughput (line)", Inches(0.4), Inches(3.95), Inches(7.4))
bar_chart(sl, Inches(0.5), Inches(4.35), Inches(7.0), Inches(1.9),
          data=[("iq8",135.2),("iq9",150.8),("iq12",197.4),("iq16",254.0)],
          max_val=280, bar_color=BLUE,
          overlay_line=[5.0,5.0,5.0,5.0], line_max=6.0,
          line_label="UL ~5.0 Mbps — flat", ylabel="FH Mbps")

# findings (right column)
callout(sl,
    "FINDING\nCompressing IQ from 16→8 bits cuts fronthaul load 47%\n(254 → 135 Mbps) with NO loss of UL throughput or quality.",
    Inches(8.1), Inches(1.65), Inches(4.8), Inches(1.5), bg=GREENBG, edge=GREEN, size=13.5)
callout(sl,
    "Why UL stays flat:\nthe fronthaul link here has huge spare capacity (uses <5%), "
    "so saving FH bytes does not change the air throughput.",
    Inches(8.1), Inches(3.3), Inches(4.8), Inches(1.45), bg=LBLUE, size=12.5)
callout(sl,
    "To expose a compression-vs-quality trade-off, constrain the FH pipe (Eval 4) "
    "or raise the load with MIMO / wider BW (Eval 3 & 6).",
    Inches(8.1), Inches(4.9), Inches(4.8), Inches(1.35), bg=TANBG, edge=ORANGE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 5 — EVAL 2: SNR vs UL
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 2 — Link Quality (SNR) vs UL Throughput",
          "Axis is TIME-DOMAIN RX SNR (the real channel SNR) injected by the vrtsim AGC")

chip(sl, "Time-domain SNR — AGC-controlled (validated)", Inches(0.4), Inches(1.3), Inches(4.6))
table(sl,
    ["TD SNR", "UL Mbps", "Jitter ms"],
    [["20 dB", "4.995", "1.83"],
     ["8 dB",  "2.148", "4.92"]],
    x=Inches(0.4), y=Inches(1.62), w=Inches(4.6),
    col_w=[Inches(1.5), Inches(1.6), Inches(1.5)], row_h=Inches(0.42), font=13)

chip(sl, "Channel-model runs (ULSCH → time-domain)", Inches(0.4), Inches(3.0), Inches(4.6))
table(sl,
    ["ULSCH dB", "TD dB", "UL Mbps"],
    [["32.8","~16","2.67"],["33.0","~16","2.83"],["35.9","~19","3.57"],
     ["39.2","~22","4.96"],["42.3","~25","4.98"],["46.3","~29","4.98"]],
    x=Inches(0.4), y=Inches(3.32), w=Inches(4.6),
    col_w=[Inches(1.6), Inches(1.4), Inches(1.6)], row_h=Inches(0.33), font=12)

# scatter plot (right)
px0, py0, pw, ph = Inches(5.4), Inches(1.7), Inches(7.4), Inches(3.35)
rect(sl, px0, py0, pw, ph, fill=GRAY, line=MGRAY)
# axes
rect(sl, px0, py0 + ph - Inches(0.02), pw, Inches(0.02), fill=BLACK)
rect(sl, px0, py0, Inches(0.02), ph, fill=BLACK)
smin, smax, umin, umax = 5, 32, 0, 6
def XY(s, u):
    fx = px0 + (s - smin)/(smax - smin) * pw
    fy = py0 + ph - (u - umin)/(umax - umin) * ph
    return fx, fy
for s in (10,15,20,25,30):
    x,_ = XY(s,0); text(sl, str(s), x-Inches(0.2), py0+ph+Inches(0.02), Inches(0.4), Inches(0.22), size=9, align=PP_ALIGN.CENTER)
for u in (1,2,3,4,5):
    _,y = XY(smin,u); text(sl, str(u), px0-Inches(0.32), y-Inches(0.11), Inches(0.28), Inches(0.22), size=9, align=PP_ALIGN.RIGHT)
text(sl, "Time-domain RX SNR (dB)", px0+pw/2-Inches(1.2), py0+ph+Inches(0.24), Inches(2.4), Inches(0.24), size=11, align=PP_ALIGN.CENTER)
text(sl, "UL\nMbps", px0-Inches(0.62), py0+ph/2-Inches(0.25), Inches(0.5), Inches(0.5), size=11, align=PP_ALIGN.CENTER)
agc = [(20,4.995),(8,2.148)]
scat = [(15.8,2.67),(16.0,2.83),(18.9,3.57),(22.2,4.96),(25.3,4.98),(29.3,4.98)]
for s,u in scat:
    x,y = XY(s,u); rect(sl, x-Inches(0.06), y-Inches(0.06), Inches(0.12), Inches(0.12), fill=BLUE)
for s,u in agc:
    x,y = XY(s,u); rect(sl, x-Inches(0.08), y-Inches(0.08), Inches(0.16), Inches(0.16), fill=DARK)
text(sl, "■ AGC-controlled (exact)     ■ channel-model runs (converted)", px0+Inches(0.15), py0+Inches(0.08),
     Inches(6.5), Inches(0.25), size=10, color=DARK)

callout(sl,
    "Note:  time-domain SNR = real channel SNR.  The post-FFT (ULSCH) SNR reads ~17 dB higher from OFDM "
    "processing gain — so the channel-model runs (32–46 dB ULSCH) are shown at their true ~16–29 dB time-domain values.",
    Inches(0.4), Inches(5.78), Inches(12.5), Inches(0.5), bg=GRAY, edge=MGRAY, size=11.5, color=BLACK)
callout(sl,
    "FINDING:  UL throughput tracks the real (time-domain) SNR monotonically — 20 dB → 5.0 Mbps, 8 dB → 2.1 Mbps — "
    "and jitter rises as SNR falls. The demo can sweep link quality on demand.",
    Inches(0.4), Inches(6.34), Inches(12.5), Inches(0.66), bg=GREENBG, edge=GREEN, size=13)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 6 — EVAL 3: MIMO
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 3 — MIMO Scaling & Fronthaul Dimensioning",
          "Add antennas (1×1 → 4×4)  ·  how does fronthaul load grow?")

chip(sl, "Measured (iq9, 10 MHz, mobility channel)", Inches(0.4), Inches(1.3), Inches(7.4))
table(sl,
    ["Antennas", "FH total Mbps", "UL Mbps", "Result"],
    [["1×1", "150.8",  "4.999", "stable"],
     ["2×2", "301.5",  "4.98",  "stable"],
     ["4×4", "1016.1", "4.998", "works (compute-heavy)"]],
    x=Inches(0.4), y=Inches(1.65), w=Inches(7.4),
    col_w=[Inches(1.5), Inches(2.2), Inches(1.6), Inches(2.1)],
    row_h=Inches(0.46), font=13,
    cell_colors={(2,3): TANBG})

chip(sl, "Fronthaul total load (Mbps) scales with antenna count", Inches(0.4), Inches(3.5), Inches(7.4))
bar_chart(sl, Inches(0.5), Inches(3.9), Inches(7.0), Inches(2.2),
          data=[("1×1",150.8),("2×2",301.5),("4×4",1016.1)],
          max_val=1100, bar_color=BLUE, ylabel="FH Mbps")

callout(sl,
    "FINDING\nFronthaul load scales ~linearly with antennas:\n1×1 → 2×2 → 4×4  =  151 → 302 → 1016 Mbps.\n"
    "Useful for dimensioning the FH link for a target MIMO order.",
    Inches(8.1), Inches(1.65), Inches(4.8), Inches(1.85), bg=GREENBG, edge=GREEN, size=13)
callout(sl,
    "UL goodput stays ~5 Mbps across all configs — at this bandwidth the air "
    "scheduler, not the fronthaul, sets the rate.",
    Inches(8.1), Inches(3.65), Inches(4.8), Inches(1.4), bg=LBLUE, size=12.5)
callout(sl,
    "4×4 real-time channel emulation is compute-heavy on a single host — "
    "it works but is near the box's CPU limit.",
    Inches(8.1), Inches(5.2), Inches(4.8), Inches(1.25), bg=TANBG, edge=ORANGE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 7 — EVAL 4: FH LATENCY
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 4 — Fronthaul Timing Budget Sensitivity",
          "Tighten the fronthaul delivery window  ·  when does the link start to break?")

chip(sl, "Measured (2×2, iq9) — tightening the FH delivery deadline", Inches(0.4), Inches(1.3), Inches(7.4))
table(sl,
    ["FH window (µs)", "Packets dropped", "UL Mbps", "Status"],
    [["200 – 300", "0",         "~5.0", "clean"],
     ["350",       "~8",        "4.7",  "first drops"],
     ["400",       "~120",      "4.0",  "knee"],
     ["450",       "~130,000",  "2.5",  "degraded"],
     ["≥ 600",     "very high", "0",    "FAIL"]],
    x=Inches(0.4), y=Inches(1.62), w=Inches(7.4),
    col_w=[Inches(1.9), Inches(2.2), Inches(1.4), Inches(1.9)],
    row_h=Inches(0.40), font=12,
    cell_colors={(2,1):ORNGBG,(3,1):REDBG,(3,3):REDBG,(4,3):REDBG})

chip(sl, "Packets dropped (log, bars)  +  UL Mbps (line)", Inches(0.4), Inches(4.12), Inches(7.4))
# log-scale bars for dropped packets — headroom so value labels clear the chip
data = [("250µs",0),("350µs",8),("400µs",120),("450µs",130000),("600µs",1e6)]
ul_line = [5.0, 4.7, 4.0, 2.5, 0.0]
bars_top = Inches(4.78); plot_h = Inches(1.55)
baseline = bars_top + plot_h
x0 = Inches(0.5); w0 = Inches(7.0); n = len(data); slot = w0/n
bar_w = Inches(0.78)
maxlog = 7.5
rect(sl, x0, baseline, w0, Inches(0.02), fill=BLACK)
centers=[]
for i,(lbl,val) in enumerate(data):
    lv = math.log10(val) if val >= 1 else 0
    bh = plot_h*(lv/maxlog) if val>=1 else Inches(0.02)
    bx = x0 + slot*i + (slot-bar_w)/2
    by = baseline - bh
    col = GREEN if val==0 else (ORANGE if val<1000 else RED)
    rect(sl, bx, by, bar_w, bh, fill=col)
    lab = "0" if val==0 else ("~130k" if val==130000 else ("crash" if val>=1e6 else f"~{int(val)}"))
    text(sl, lab, bx-Inches(0.15), by-Inches(0.22), bar_w+Inches(0.3), Inches(0.2),
         size=9, bold=True, color=col, align=PP_ALIGN.CENTER)
    text(sl, lbl, x0+slot*i, baseline+Inches(0.03), slot, Inches(0.24), size=10, align=PP_ALIGN.CENTER)
    centers.append(bx+bar_w/2)
# UL line on 0..6 scale
ulmax=6.0; pts=[]
for i,v in enumerate(ul_line):
    ly = baseline - plot_h*(v/ulmax); pts.append((centers[i],ly))
for i in range(len(pts)-1):
    (a,b),(c,d)=pts[i],pts[i+1]
    seg=sl.shapes.add_connector(2,a,b,c,d); seg.line.color.rgb=DARK; seg.line.width=Pt(2.25); seg.shadow.inherit=False
for (a,b) in pts:
    rect(sl, a-Inches(0.05), b-Inches(0.05), Inches(0.1), Inches(0.1), fill=DARK)

callout(sl,
    "FINDING\nThere is a sharp 'knee' in the fronthaul timing budget:\n"
    "the link is clean down to ~350 µs, then collapses between 400–450 µs "
    "(dropped packets jump ×1000, UL halves), and fails below the budget.",
    Inches(8.1), Inches(1.62), Inches(4.8), Inches(2.05), bg=GREENBG, edge=GREEN, size=13)
callout(sl,
    "This is exactly the kind of timing-margin test you want before deploying "
    "on a real fronthaul link with finite latency.",
    Inches(8.1), Inches(3.85), Inches(4.8), Inches(1.4), bg=LBLUE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 8 — EVAL 5: MOBILITY
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 5 — Mobility / Time-Varying Channel",
          "Sweep a time-varying fading channel at 3 / 60 / 120 km/h-equivalent")

chip(sl, "Measured (2×2, iq9, fading channel)  ·  SNR = time-domain (real channel) SNR", Inches(0.4), Inches(1.3), Inches(12.5))
table(sl,
    ["Mobility", "TD SNR dB", "UL Mbps", "Result"],
    [["3 km/h",   "~16",    "2.67", "ok (low-SNR run)"],
     ["3 km/h",   "~22–29", "~4.98", "ok"],
     ["60 km/h",  "~21–27", "4.4 – 4.98", "ok"],
     ["120 km/h", "—",      "0",    "FAIL — DL sync cannot lock"]],
    x=Inches(0.4), y=Inches(1.6), w=Inches(12.5),
    col_w=[Inches(2.2), Inches(2.2), Inches(3.0), Inches(5.1)],
    row_h=Inches(0.44), font=13,
    cell_colors={(3,3):REDBG,(3,2):REDBG})

callout(sl,
    "FINDING:  at good SNR the link is robust to mobility — UL stays ~5 Mbps up to 60 km/h-equivalent. "
    "At 120 km/h the very fast fading prevents the UE from locking onto the downlink.",
    Inches(0.4), Inches(4.1), Inches(12.5), Inches(0.85), bg=GREENBG, edge=GREEN, size=13.5)
callout(sl,
    "Scope note:  the demo models mobility as a channel time-variation factor, not a true Doppler shift, "
    "so this evaluates link robustness to fast fading rather than precise velocity effects.",
    Inches(0.4), Inches(5.05), Inches(12.5), Inches(0.78), bg=TANBG, edge=ORANGE, size=12.5)
callout(sl,
    "Also: uplink channel estimation is per-slot, so uplink data is largely insensitive to channel aging — "
    "the mobility effect shows up mainly in initial downlink synchronisation.",
    Inches(0.4), Inches(5.93), Inches(12.5), Inches(0.78), bg=LBLUE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 9 — EVAL 6: BANDWIDTH
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Evaluation 6 — Bandwidth Scaling & Fronthaul Headroom",
          "How much fronthaul headroom is there, and what limits wider bandwidth?")

chip(sl, "Fronthaul capacity vs actual demo load", Inches(0.4), Inches(1.3), Inches(7.4))
table(sl,
    ["Fronthaul", "Capacity / load", "Utilisation"],
    [["Link capacity (measured)", "6.36 Gbps", "—"],
     ["10 MHz · 1×1 · iq9",       "0.15 Gbps", "2 %"],
     ["10 MHz · 4×4 · iq16",      "1.02 Gbps", "16 %"]],
    x=Inches(0.4), y=Inches(1.65), w=Inches(7.4),
    col_w=[Inches(3.4), Inches(2.2), Inches(1.8)],
    row_h=Inches(0.46), font=13,
    cell_colors={(0,1):GREENBG,(1,2):GREENBG,(2,2):GREENBG})

chip(sl, "Wider bandwidth — current status", Inches(0.4), Inches(3.5), Inches(7.4))
table(sl,
    ["Bandwidth", "Status"],
    [["10 MHz (24 PRB)", "works ✓"],
     ["40 MHz (106 PRB)", "not yet — needs PHY rework"],
     ["≥ 50 MHz / 100 MHz", "not yet — compute / PHY limits"]],
    x=Inches(0.4), y=Inches(3.85), w=Inches(7.4),
    col_w=[Inches(3.6), Inches(3.8)],
    row_h=Inches(0.46), font=13,
    cell_colors={(0,1):GREENBG,(1,1):TANBG,(2,1):TANBG})

callout(sl,
    "FINDING\nThe fronthaul is massively over-provisioned — the demo uses "
    "at most 16% of link capacity, so fronthaul bandwidth is never the bottleneck.",
    Inches(8.1), Inches(1.65), Inches(4.8), Inches(1.85), bg=GREENBG, edge=GREEN, size=13)
callout(sl,
    "The cell currently runs at 10 MHz. Going wider is a known next step that "
    "needs PHY-layer rework and more real-time compute — not more fronthaul.",
    Inches(8.1), Inches(3.65), Inches(4.8), Inches(1.7), bg=LBLUE, size=12.5)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 10 — WHAT THIS DEMO CAN EVALUATE
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "What This Demo Can Evaluate", "One platform, six evaluation axes")

table(sl,
    ["Evaluation", "What we sweep", "What we find"],
    [["IQ compression",  "IQ width 8→16",         "FH load −47% at iq8, no UL loss"],
     ["Link quality",    "RX SNR (AGC)",          "UL tracks SNR: 5.0 → 2.1 Mbps (20→8 dB)"],
     ["MIMO scaling",    "1×1 → 4×4 antennas",    "FH load scales ×N (151 → 1016 Mbps)"],
     ["FH timing budget","FH delivery window",    "sharp knee at 400–450 µs"],
     ["Mobility",        "fading speed 3–120 km/h","robust ≤60 km/h; DL sync fails at 120"],
     ["Bandwidth / FH",  "PRB / antennas / iq",   "FH ≤16% utilised — large headroom"]],
    x=Inches(0.4), y=Inches(1.35), w=Inches(12.5),
    col_w=[Inches(2.7), Inches(3.3), Inches(6.5)],
    row_h=Inches(0.62), font=13.5)

callout(sl,
    "Take-away:  one host lets us SEE the system trade-offs — compression vs fronthaul load, SNR vs throughput, "
    "MIMO vs fronthaul load, timing budget vs link, bandwidth vs fronthaul headroom — with real DPDK fronthaul "
    "and real over-the-air goodput.",
    Inches(0.4), Inches(5.65), Inches(12.5), Inches(1.0), bg=DARK, edge=DARK, size=14, color=WHITE, bold=True)


# ══════════════════════════════════════════════════════════════════════════
# SLIDE 11 — KEY FINDINGS / NUMBERS
# ══════════════════════════════════════════════════════════════════════════
sl = prs.slides.add_slide(BLANK)
title_bar(sl, "Key Findings", "All numbers measured on the demo (UL received at the 5GC, iperf3 UDP)")

table(sl,
    ["Metric", "Result"],
    [["Baseline UL (10 MHz, 1×1, iq9)",       "5.0 Mbps · 0% loss · 1.8 ms jitter"],
     ["IQ compression iq16 → iq8",            "FH load 254 → 135 Mbps (−47%), UL unchanged"],
     ["UL vs SNR",                            "20 dB → 5.0 Mbps   /   8 dB → 2.1 Mbps"],
     ["MIMO FH load 1×1 / 2×2 / 4×4",        "151 / 302 / 1016 Mbps"],
     ["FH timing knee",                       "clean ≤350 µs → collapses 400–450 µs"],
     ["Mobility robustness",                  "stable ≤60 km/h-equiv; fails at 120"],
     ["Fronthaul link capacity",              "6.36 Gbps — demo uses ≤16%"]],
    x=Inches(0.4), y=Inches(1.35), w=Inches(12.5),
    col_w=[Inches(4.8), Inches(7.7)],
    row_h=Inches(0.6), font=14,
    cell_colors={(0,1):GREENBG,(2,1):GREENBG})

callout(sl,
    "Bottom line:  a single-host O-RAN 7.2 split that lets us explore system-level trade-offs across "
    "compression, SNR, MIMO, latency, PRB / bandwidth, and mobility.",
    Inches(0.4), Inches(6.2), Inches(12.5), Inches(0.85), bg=BLUE, edge=BLUE, size=14, color=WHITE, bold=True)


out = "/home/jesse/oran_lab/OAI_OranSplit_Demo.pptx"
prs.save(out)
print("Saved:", out)
