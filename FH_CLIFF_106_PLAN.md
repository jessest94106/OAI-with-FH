# FH congestion cliff at 106 PRB + 10 Gbps software cap (2026-07-27)

**Why 106, not 189/273** — user's call, and it is the better design:

1. **Known-good config.** Fixed noise works at 106 for every IQ width (ledger FULL FACTORIAL).
   189 only started working after the noise-table fix; 273 is still unverified.
2. **No fragmentation confound.** 106 x 49 = 5194 B < 9600 MTU => single frame at ALL widths.
   273 fragments above w11, which changes packet count and per-frame overhead mid-sweep.
3. **RU real-time headroom.** 106 runs at 61.44 Msps vs 122.88 at 189/273 — roughly 2x the
   wall-clock margin. At 189/273 the RU sits near its own real-time limit, so a "cliff" there
   risks being RU overrun misread as FH congestion. At 106 that confound is far away.
   **This is the strongest argument** — it protects the causal claim, not just the numbers.
4. **10 Gbps is the physical link.** The box has a 10G SFP link, so a 10 Gbps FH is the real
   hardware limit rather than an arbitrary target.

## Predicted numbers (first principles, validated to ~1% at 189)

Per-antenna continuous UL @106 PRB / 30 kHz / 16-bit I+Q:
`1272 SC x 32 bit x 28000 sym/s = 1.140 Gb/s`; x16 ant = **18.24 Gb/s** at 100% UL.
TDD duty 46/70 = 0.657 => **11.98 Gb/s at w16** = **240 Mbps wall** (TS=0.02).
Linear in width: `wall_Mbps(w) ~= 240 x w/16 = 15.0 x w`.

Cap rungs (i40e quantizes to 50, then +3%): 150 -> 154.5 Mbps (7.7 Gb/s eff) |
200 -> 206 Mbps (10.3 Gb/s eff) | 250 -> 257.5 (12.9 Gb/s eff, ABOVE w16 => never binds).

| cap | wire limit | crossing width | predicted cliff |
|-----|-----------|----------------|-----------------|
| 200 | 206 Mbps  | w = 206/15.0 = 13.7 | between **w13 and w14** |
| 150 | 154.5 Mbps| w = 154.5/15.0 = 10.3 | between **w10 and w11** |

**The design's strength: the cliff position is PREDICTED QUANTITATIVELY and tested at two
different caps.** If the cliff moves from w13/14 to w10/11 exactly as the cap changes, FH
congestion is confirmed as the mechanism. If it does not move, the cliff is something else
(RU overrun, CN, per-UE fault) and the cap was never the cause.

## P1 RESULT (2026-07-27) — model confirmed, fit refined

| width | predicted | measured | err | pps | avg frame | PRACH |
|-------|-----------|----------|-----|-----|-----------|-------|
| w9    | 135 Mbps  | **142**  | +5.2% | 6272 | 2842 B | 56.4 dB |
| w16   | 240 Mbps  | **243**  | +1.2% | 6274 | 4845 B | 55.7 dB |

**Packet rate is IDENTICAL at both widths (6272 vs 6274 pps)** — IQ width changes frame SIZE,
not packet COUNT. One packet per section per symbol regardless of width. So per-packet header
overhead is a fixed additive term, which is why the error shrinks as width grows.

Measured fit (replaces the 15.0 x w estimate): **`load_Mbps = 12.1 + 14.43 x width`**
(slope = payload, intercept 12.1 = width-independent header overhead).

Refined crossings — both still land BETWEEN widths, so the brackets are clean:
| cap | limit | w13 | w14 | crossing | bracket |
|-----|-------|-----|-----|----------|---------|
| 200 | 206 Mbps | 200 (97%) | 214 (104%) | w13.4 | **w13 / w14** |
| 150 | 154.5 Mbps | w9 142 (92%) | w10 156 (101%) | w9.9 | **w9 / w10** |

w10 at cap 150 is only 1% over the limit — a strong test of the wall-vs-slope finding: if
1% overload collapses the link, the deadline mechanism is confirmed.

## RESULT 2 — NO PRE-CLIFF DEGRADATION (P5b, 180 s converged, cap 200)

| w | FH load | util | state | agg sim Mbps | end MCS | PRACH |
|---|---------|------|-------|--------------|---------|-------|
| w10 | 156 | 76% | alive | **177.8** | 28,28 | 56.4 |
| w11 | 171 | 83% | alive | **177.8** | 28,28 | 56.4 |
| w12 | 185 | 90% | alive | **177.9** | 28,28 | 56.4 |
| w13 | 200 | 97% | alive | **177.8** | 28,28 | 56.4 |
| w14 | 214 | 104% | **DEAD** | 0 | - | 20.6 |

**Throughput is FLAT to 0.06% across 76 -> 97% utilisation, then zero.** All four alive
points converge to MCS 28/28 and 177.8 Mbps. No droop, no MCS backoff, no early loss —
the paced RU source shows the same wall-not-slope behaviour as the synthetic generator.
So there is NO usable warning region: the last healthy point is at full performance.

**Why throughput is width-independent**: IQ width is a FRONTHAUL TRANSPORT parameter; it
changes bytes on the wire, not bits over the air. Air capacity is set by PRB/MCS/layers, so
every surviving width delivers identical throughput. Width only decides whether the FH can
carry the samples at all.

**OLLA convergence (measured)**: MCS ramps 7 -> 28 over ~160 s (7,1 @32s | 13,8 @65s |
20,14 @97s | 26,21 @129s | 28,27 @162s | 28,28 @194s). 60 s runs read MCS 17/10 and ~60
Mbps = 34% of converged. **180 s is the minimum for any throughput claim.** Cross-check:
189 PRB gave 294.7 at MCS 28/28; x(106/189) predicts 165 vs 177.8 measured (+8%).

## RESULT — FH CONGESTION CLIFF CONFIRMED (2026-07-27)

**The cliff moves with the cap exactly as predicted. Mechanism = FH congestion, confirmed.**

| cap | limit | alive (util) | dead (util) | predicted crossing | measured |
|-----|-------|--------------|-------------|--------------------|----------|
| 200 | 206 Mbps | w13 200 (97%) MCS 18/11 | w14 214 (104%) | w13.4 | **w13/w14** |
| 150 | 154 Mbps | w9 142 (92%) MCS 17/10  | w10 156 (101%) | w9.9  | **w9/w10**  |

Same carrier, same everything — only the cap changed, and the cliff relocated 4 widths.
That is the discriminating test the earlier sweeps never had: an RU-overrun or per-UE fault
would have stayed at a fixed width.

**97% healthy, 101% dead.** w10 is only 1% over the limit and fails completely — no partial
degradation, no reduced throughput, no elevated TBLER. Confirms wall-not-slope from the
synthetic clamp test, now with the real paced RU source.

**Failure signature = stale-zero, not corruption**: PRACH peak drops to the 20.6 dB noise
floor (healthy 56.4) and NO attach occurs at all. Late FH packets leave the destination
buffer untouched, so the DU correlates against stale zeros — the UE signal is not degraded,
it is absent. Identical to the pre-noise-fix failure mode, reached from congestion instead.

**Control (isolates the cap as cause)**: w16 UNCAPPED attaches fine (P1: 243 Mbps, PRACH
55.7); w16 at cap 200 is dead. Same width, same config, only the cap differs.

## Plan

- **P1 load check (uncapped, 2 runs)**: w9, w16. Expect 135 and 240 Mbps wall.
  Gate: within ~5% of prediction, else re-derive before sweeping.
- **P2 cap 200 (6 runs)**: w11..w16, clean run per point (hysteresis — never step a cap
  mid-run). Expect w11-w13 healthy, w14-w16 collapse.
- **P3 cap 150 (5 runs)**: w8..w12. Expect w8-w10 healthy, w11+ collapse.
- Per run: attach 2/2, per-UE Mbps, MCS, true TBLER (round1/round0), preSNR, DU late count,
  plus in-run wire Mbps + cap-present readback.
- **N>=2 at the two widths bracketing each predicted cliff** — the intermittent single-UE
  fault (w10 UE0, w12 UE1 at 189) is the dominant error term and can fake a cliff.

## Risks / cons

- Collapse is non-recovering (clamp test: 25 s at 60% of load desynced both UEs permanently),
  so every point is a fresh run; no in-run cap stepping. Cost: ~11 runs x 7 min ~= 1.3 h.
- 10.3 Gb/s effective is a smaller FH than the 25 Gb/s originally scoped — deliberate: it is
  what the physical 10G link represents and what 106 PRB can actually saturate.
- Cap granularity is coarse at this scale (50 Mbps steps = 2.6 Gb/s effective), so cliff
  placement can only be tested at two cap values, not a continuum.
- Predicted crossings sit between integer widths (13.7, 10.3), so the cliff should land in a
  single-width bracket; if it lands two widths early, suspect RU overrun rather than FH.
