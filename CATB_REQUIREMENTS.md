# Cat-B UL implementation — REQUIREMENTS
Branch `catb-srs-ru-mmse`. Companion to `CATB_STEPS.md` (how) and
`CATB_SRS_RU_MMSE_SCOPE.md` (why). This file is the contract: **numbered, testable,
each with an acceptance check.** If a requirement cannot be tested, it is not a
requirement — delete it.

Legend: **[M]** mandatory · **[S]** should · **[N]** non-goal

---

## R1 — Compression policy

> **STATUS 2026-07-27: R1.1 and R1.3 are PAUSED (not cancelled).** Decision reversed to
> **compress SRS** at the PUSCH width — see `CATB_SRS_COMPRESSION_PLAN.md` for the scope,
> validation plan (V1-V4) and un-pause triggers (T1-T4). R1.2, R1.5, R1.6 remain active;
> R1.5 (quantisation-SNR margin) is now the governing rule, and V4's uncompressed control
> point is what retires the question.

**R1.1 [M — PAUSED] SRS symbols SHALL NOT be compressed.** SRS travels at full int16 I/Q
(`iqWidth=16`, `compMeth=0` / no compression) on its own eAxC, always, regardless of the
PUSCH compression setting.
*Rationale:* SRS quantisation noise propagates into the beamforming weights and therefore
degrades **every** data symbol until the next sounding, whereas PUSCH quantisation noise
degrades only the samples it rides on. The fronthaul saving does not justify it: at 106 PRB
/ 16 antennas / 20 ms sounding, uncompressed SRS costs **0.65 Mbps of wire, ~0.5% of the
142 Mbps PUSCH load**. Compressing it would buy back a fraction of a percent while putting
a systematic error on all spatial processing.
*Acceptance:* capture the SRS eAxC and confirm `udCompHdr` reports no compression and
16-bit width; measured SRS wire bytes match `16 ant x nPRB x 12 x 2 x 2 B` exactly.

**R1.2 [M] PUSCH data symbols SHALL remain compressible** with the existing BFP path
(`IQ_WIDTH`, `COMP_METH=1`), independently of R1.1. The two settings SHALL be separately
configurable and SHALL NOT be coupled in code.
*Acceptance:* a run with `IQ_WIDTH=9` shows 9-bit BFP on the PUSCH eAxC and 16-bit
uncompressed on the SRS eAxC in the same slot.

**R1.3 [M — PAUSED] The implementation SHALL add an explicit SRS compression config path.**
The xran in this tree has `iqWidth`/`compMeth` (data) and `iqWidth_PRACH`/`compMeth_PRACH`
(PRACH) but **no SRS equivalent** (`xran_fh_o_du.h:634-637`, `struct xran_srs_config:591`),
so SRS would silently inherit the PUSCH width. Add `iqWidth_SRS`/`compMeth_SRS` mirroring
the PRACH pair, defaulting to 16/none.
*Acceptance:* setting `IQ_WIDTH=4` leaves SRS at 16-bit; a unit assertion fails the build
if the SRS width is ever taken from the data width.

**R1.4 [S] — REVISED.** Track-A reference symbols (forwarded DMRS) MAY carry the same BFP
compression as the data. Making them uncompressed would require compression to vary **per
symbol within one flow**, which is far harder than the per-flow SRS case in R1.1 and is not
justified: quantisation noise only matters when it approaches thermal noise, and at w9 BFP
the quantisation SNR (~40-50 dB) sits ~20 dB below an operating SNR of 20-30 dB. It applies
identically to every point in the delay sweep, so it is a constant, not a confound.
**The real rule is R1.5, of which R1.1 is the safe implementation.**

**R1.5 [M] Reference-signal quantisation SNR SHALL stay well clear of operating SNR**
(target >=15 dB margin). This is the physical requirement; "16-bit uncompressed" (R1.1) is
simply the setting that always satisfies it. Consequence: at narrow widths (~w4-w6) the
margin closes and reference-signal compression starts to degrade weights — if a future
sweep goes there, R1.1 becomes load-bearing rather than belt-and-braces.
*Acceptance:* for any configured width, report reference-signal quantisation SNR and
measured operating SNR side by side; flag any point with <15 dB margin.

**R1.6 [S] Sequencing.** The SRS compression path (R1.3) is only reachable at STEP 5
(Track B) — Track A uses DMRS and never transports SRS. Do NOT build the SRS config path
before it is needed; compressing SRS is the zero-work default, so the work only buys value
once SRS actually carries the weights.

---

## R2 — Functional split

**R2.1 [M]** Channel estimation SHALL execute in the DU. **R2.2 [M]** Beamforming weight
computation SHALL execute in the DU. **R2.3 [M]** Weight *application* (MMSE combining of
16 antennas into N layers) SHALL execute in the RU.
*Acceptance:* with `VRTSIM_CATB_UL=1`, the DU receives N_layer streams for data symbols;
no per-antenna PUSCH data reaches the DU.

**R2.4 [M]** The RU SHALL NOT compute weights. It applies what it is given.
*Acceptance:* code review — no matrix inversion in the RU path.

**R2.5 [M]** Weights SHALL be per-PRB (frequency-selective), not per-slot-wideband.
*Acceptance (REVISED 2026-07-28 — the original "per-antenna phase matches the configured CDL
arrival angles" is WRONG BY CONSTRUCTION: MMSE weights are not steering vectors. w_0 is
approximately the projection of h_0 onto the null space of h_1, so nulling deliberately rotates
the weight away from the matched-filter direction; CDL-A's angular spread removes any clean
phase ramp as well — measured phase coherence 0.4-0.5, exactly as multipath predicts):*
 (a) **inter-layer orthogonality** `|<w0,w1>|^2/(|w0|^2 |w1|^2)` near 0 — the defining property
 of a spatial separator. MEASURED 0.028-0.032.
 (b) **frequency selectivity** — adjacent-PRB weight correlation below 1 but well above 0,
 proving per-PRB weights carry information a wideband set would flatten. MEASURED 0.91-0.96,
 which also justifies sampling at the PRB centre.

---

## R3 — The control loop (the thing under study)

**R3.1 [M]** Loop delay SHALL be configurable in **slots**, not wall-clock time
(`VRTSIM_BFW_DELAY_SLOTS`). At TS=0.02 a real 100 us fronthaul delay is 2 us of sim time
and would be invisible; wall-clock delay cannot represent this loop.
*Acceptance:* `d=2` demonstrably applies slot N-2's weights to slot N (assert on the
frame/slot tag carried in the weight record).

**R3.2 [M]** Every weight record SHALL carry `{frame, slot}` of the measurement it derives
from, and the RU SHALL log **weight age in slots** alongside throughput.
*Rationale:* stale weights lower SINR, and OLLA then walks MCS down over ~160 s. Without
age logged next to throughput, the fast weight loop and the slow link-adaptation loop are
indistinguishable in the output.
*Acceptance:* logged age equals the configured `d` for every applied set.

**R3.3 [M]** `d=0` SHALL reproduce the Cat-A baseline within 1% (177.8 sim Mbps, MCS 28/28
at 106 PRB / w9 / 180 s).
*Rationale:* a broken receiver still produces a smooth, convincing, meaningless degradation
curve. This gate is the only thing separating the two.

**R3.4 [S]** The weight delivery path SHOULD respect the real C-plane window
(`T1a_cp_ul = 285-535 us` before the target symbol, `du_test.conf:174`) when the emulation
is later compared against a standards-conformant implementation.

---

## R4 — Fronthaul behaviour

**R4.1 [M]** Measured UL FH load SHALL fall to ~31% of Cat-A on the Track-A path
(3 reference symbols at 16 antennas + 11 data symbols at N layers) and ~12.5% on Track B.
*Acceptance:* `ethtool -S eno1np0 | grep port.tx_bytes` during traffic; 142 Mbps Cat-A
baseline at 106/w9 -> ~44 Mbps Track A.

**R4.2 [M]** With `VRTSIM_CATB_UL=0` the fronthaul byte stream SHALL be byte-identical to
today's Cat-A.
*Acceptance:* wire rate matches the 142 Mbps baseline within measurement noise.

**R4.3 [S]** Cat-B SHALL be tested at 97% FH utilisation, where Cat-A was measured healthy.
*Rationale:* the BFW delivery window is ~250 us wide while a fronthaul at its cap adds
12.7 ms of queueing — congestion should break the **control** plane roughly 25x before it
breaks the data plane. This is a prediction worth falsifying.

---

## R5 — Safety and reversibility

**R5.1 [M]** Every new behaviour SHALL be env-gated OFF by default; the disabled path SHALL
be functionally identical to today. **R5.2 [M]** No change to the DU-side Cat-A receiver
path when Cat-B is off. **R5.3 [M]** RU per-slot combine time SHALL stay within the
real-time budget, measured and logged before and after (`VRTSIM_CATB_STATS`).
*Rationale:* RU real-time overrun has already produced two false diagnoses in this lab; it
mimics congestion and latency degradation.
*Acceptance:* combine time reported; no growth in `late`/`TOO_LATE` counters versus baseline.

**R5.4 [M]** Build in `oaicicd/test_dir/openairinterface5g/build/`, not
`cmake_targets/ran_build/build/` — the harness loads the former.

---

## R6 — Measurement validity (learned the hard way)

**R6.1 [M]** Any throughput claim SHALL come from a >=180 s run (MCS converges at ~160 s;
60 s reads ~1/3 and is invalid). 60 s is acceptable only for attach/PRACH checks.
**R6.2 [M]** Every run SHALL be preceded by a CN check
(`docker logs --since 5m oai-amf | grep -c "no SMF candidate"`; non-zero => restart core).
**R6.3 [M]** Failure triage SHALL use PRACH peak: dead + ~20 dB = fronthaul; dead + ~56 dB =
CN/attach, rerun and do not record.
**R6.4 [M]** N>=2 wherever a curve bends; the intermittent single-UE fault has faked a
result twice.
**R6.5 [M]** An SU control arm (`N_UE=1`) SHALL accompany the MU sweep — stale weights
should degrade MU separation before SU array gain; identical degradation implies a bug.

---

## R7 — Non-goals

**N7.1** Real O-RAN C-plane section-extension BFW encoding (emulated in vrtsim).
**N7.2** DL beamforming — the existing codebook port (`nr-oru.c:600`) already covers it.
**N7.3** Cat-B at 189/273 PRB — 106 is chosen for RU real-time headroom.
**N7.4** UL codebook/TPMI — UEs are 1-TX.
**N7.5** SRS-driven MU pairing (separate study, up to 12x potential).
**N7.6** Compressing SRS — explicitly rejected, see R1.1.
