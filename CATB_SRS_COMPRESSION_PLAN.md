# Compressed SRS — scope (decision + validation plan)
Branch `catb-srs-ru-mmse`, 2026-07-27. Supersedes R1.1/R1.3 of `CATB_REQUIREMENTS.md`,
which are now **PAUSED, not cancelled** (un-pause triggers in section 5).

## 1. Decision

**SRS rides the existing BFP path at the PUSCH `iqWidth`/`compMeth`.** No new config, no
xran change, no `iqWidth_SRS` pair.

**This is an effort decision, not a bandwidth decision — say so plainly.** Compressing SRS
saves ~0.28 Mbps of wire (0.65 -> 0.37 Mbps at w9), which is **0.6% of the ~44 Mbps Track-B
load**. Nobody would do this for the bandwidth. It is chosen because it is the zero-work
default: xran has `iqWidth`/`compMeth` (data) and `iqWidth_PRACH`/`compMeth_PRACH` (PRACH)
but **no SRS equivalent** (`xran_fh_o_du.h:634-637`), so SRS inherits the data setting
automatically and the alternative costs a config path plus per-flow verification.

## 2. THE CONSEQUENCE — IQ width becomes a double-acting knob

This is the part that actually matters, and it changes what the Cat-B sweep means.

| | Cat-A (measured today) | Cat-B with compressed SRS |
|---|---|---|
| what `iqWidth` affects | **transport only** | **transport AND weight quality** |
| throughput vs width | **flat** — 177.8 Mbps at w10/w11/w12/w13, spread 0.06% | **expected to fall at narrow widths** |
| mechanism | width changes wire bytes, not air bits | width also quantises the channel estimate that produces the weights |

We proved the Cat-A column by measurement: four widths spanning 76-97% FH utilisation gave
177.8 / 177.8 / 177.9 / 177.8 Mbps. **In Cat-B that independence should break**, because the
same knob now feeds back through the beamforming weights onto every data symbol.

**That is a clean, falsifiable prediction, and it is worth measuring for its own sake** —
it is the first place Cat-B should behave qualitatively differently from Cat-A.

## 3. Where the margin closes (estimates — to be measured, not assumed)

BFP quantisation SNR ~= `6.02 x (w - 1)` dB, minus ~4 dB for the shared per-PRB exponent
against in-block PAPR. Operating per-antenna SNR in our fixed-noise runs is ~25 dB.

| iqWidth | quant SNR (est) | margin over 25 dB operating | verdict vs R1.5 (>=15 dB) |
|---------|-----------------|------------------------------|---------------------------|
| w16 | ~86 dB | +61 | safe |
| w12 | ~62 dB | +37 | safe |
| **w9** | **~44 dB** | **+19** | **safe — our standard point** |
| w8 | ~38 dB | +13 | **marginal** |
| w7 | ~32 dB | +7 | degradation expected |
| w6 | ~26 dB | +1 | clear degradation |
| w4 | ~14 dB | -11 | quantisation dominates |

**Practical bound: compressed SRS is safe at w >= 9, marginal at w8, and should visibly
degrade weights below w7.** Our Cat-A cliff sweep used w8-w14, so Cat-B inherits a usable
range — but the bottom of it is exactly where the margin runs out.

## 4. Validation plan (folds into the existing steps, adds no new phase)

**V1 — record the margin, always.** Every Cat-B run logs reference-signal quantisation SNR
alongside measured operating SNR, and flags any point with <15 dB margin (R1.5 acceptance).
Cheap, and it turns the table above from an assumption into data. *Add at STEP 0.*

**V2 — width sweep at fixed loop delay (d=0), 106 PRB, 180 s, N>=2.**
Widths w4, w6, w8, w9, w12, w16. *Expected:* flat from w9 up, degrading below.
*This is the experiment that tests section 2's prediction.* Run it right after STEP 3's
`d=0` parity gate, before the latency sweep — it establishes which widths are safe to use
as the substrate for the latency work.

**V3 — pick the latency-sweep width from V2.** Use the narrowest width with >=15 dB margin
(expected w9). Running the latency sweep at a width where quantisation already degrades
weights would confound the two mechanisms — both degrade weight accuracy, and the sweep
could not tell them apart.

**V4 — one uncompressed control point.** At the chosen width, run a single point with SRS
forced to 16-bit. If it matches within 1%, compression is confirmed harmless at that width
and the paused path stays paused. *This is the check that retires the question.*

## 5. Un-pause triggers — build the `iqWidth_SRS` path if ANY of these happen

- **T1.** V2 shows degradation at or above the width chosen for the latency sweep.
- **T2.** V4's uncompressed control differs by >1% — compression is not harmless where we
  are operating.
- **T3.** A future sweep needs narrow widths (w4-w7) with Cat-B; there the margin is gone
  and the weights would be quantisation-limited.
- **T4.** Operating SNR rises (better channel, more array gain), which *narrows* the margin
  by raising the floor the quantisation noise must clear.

Estimated cost when un-paused: add `iqWidth_SRS`/`compMeth_SRS` mirroring the PRACH pair in
`xran_ru_config` + plumb through `oran-config.c` + verify per-flow honouring. Half a day,
well-precedented, no new concepts.

## 6. Risks

- **Confounded axes (main risk).** With one knob driving both transport and weight quality,
  a Cat-B width sweep cannot separate "less fronthaul" from "worse weights" without V4's
  uncompressed control. Do not skip V4.
- **The estimates in section 3 are estimates.** BFP effective SNR depends on in-block PAPR,
  which depends on the channel; CDL-A with 0.1 us delay spread is mild, a harsher profile
  would push the boundary upward. V1 makes this measured rather than assumed.
- **Silent inheritance.** Because SRS takes the data width implicitly, someone changing
  `IQ_WIDTH` for fronthaul reasons also changes weight quality without intending to. V1's
  logged margin is the guard against that going unnoticed.
- **Not a standards statement.** Real deployments often give SRS higher precision precisely
  to avoid this coupling. Our choice is a lab-effort tradeoff and should be labelled as such
  in any writeup.
