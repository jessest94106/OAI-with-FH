# Cat-B UL — STEP BY STEP
Execution steps for `CATB_SRS_RU_MMSE_SCOPE.md`. Branch `catb-srs-ru-mmse`.
Every step: env-gated OFF by default, one gate, stop if the gate fails.

Baseline recipe used by every verification below (106 PRB, known-good):
```bash
cd /home/jesse/oran_lab && OAI_UL_AVG_AGG=2 ADV=32768 BW=106 IQ_WIDTH=9 COMP_METH=1 \
N_UE=2 TS=0.02 CHANMOD=1 CHAN_TYPE=CDL_A CHAN_DS_US=0.1 NB_ANT_RX=16 \
VRTSIM_CDL_UE_AZ_DEG=0,90 OAI_UL_MU_COSCHED=1 OAI_UL_MU_PORTS=1 OAI_UL_MU_IRC=1 \
UESS_AGG=0,8,8,4,2 PER_UE_WAIT=700 IPERF_SECONDS=180 VRTSIM_RX_NOISE_SIGMA=7 \
bash run_multi_ue.sh
```
Reference numbers: **177.8 sim Mbps, MCS 28/28, PRACH ~56 dB, FH 142 Mbps**.
Throughput needs 180 s (MCS converges at ~160 s); 60 s reads ~1/3 and is invalid.

---

## STEP 0 — DONE 2026-07-28 (PASSED)

**Result:** `VRTSIM_CATB_STATS=1` live; baseline reproduced.

| run | agg sim Mbps | MCS | combine avg | combine max |
|-----|--------------|-----|-------------|-------------|
| 1 | 155.5 | 23,28 | 194.8 us | 581.4 us |
| 2 | **177.7** | 28,28 | 183.2 us | 618.0 us |
| 3 | **177.6** | 28,28 | 185.4 us | 568.3 us |

**RU headroom (the number STEP 3 must fit inside):** combine costs **183-195 us average,
568-618 us max** per read call. A call is `nsamps=2192` ~= one OFDM symbol at 61.44 Msps,
which gets ~1.79 ms of wall budget at TS=0.02 => **~10% of budget average, ~34% worst case**.
The max matters more than the average: a third of budget is already gone before any spatial
combining moves into the RU.

**Run 1 was the intermittent single-UE fault, NOT the instrumentation.** Signature matches
(UE0 pinned at MCS 23 while UE1 reached 28); runs 2-3 reproduce baseline within 0.1%; and
two `clock_gettime` vDSO calls (~100 ns) against a 194,800 ns combine is 0.05%, which cannot
produce -12.5%. **First measured occurrence rate for this fault: 1 in 3 at 106/w9.**

### Three defects found while instrumenting — all would have voided STEP 3's gate
1. **`run_ru.sh:112` passes an explicit env allowlist** (`sudo -E ... env VAR=...`). Anything
   not listed is dropped **silently** — the feature does nothing and the run looks healthy.
   Every new RU knob needs a line there: `VRTSIM_CATB_REF_SYMS`, `VRTSIM_CATB_UL`,
   `VRTSIM_BFW_DELAY_SLOTS` still to be added.
2. **`vrtsim_read` returns early inside the multi-UE branch** (`vrtsim.c:1915`), skipping
   `rx_samples_total`. That is the only path this lab runs, so the realtime denominator was
   **zero**, not merely mis-scaled. Fixed; accounting now runs at both exits.
3. **`rx_samples_late` counts per sub-read** (UEs x antennas x layers) vs total per call —
   32x mismatch at 2 UEs x 16 antennas. Added `rx_subreads`; report raw counts, not just a %.
   Bonus: the end-of-run summary lives in `vrtsim_end()`, which never runs (harness SIGKILLs),
   so vrtsim's final statistics have never been visible in ANY run.

---

## STEP 0 — instrument the RU before changing anything

**Why first:** moving combining into the RU deletes the DU-side instrumented receiver that
every past diagnosis in this lab depended on. Replace the instrument before removing it.

**Do:** in `radio/vrtsim/vrtsim.c`, add under `VRTSIM_CATB_STATS=1`:
- per-slot combine wall time (ns), min/avg/max, logged every 1000 slots
- slot counter and (later) weight age in slots
Follow the existing env-gated pattern at `vrtsim.c:478-498` (`VRTSIM_UL_MU_STEER`).

**Verify:** run the baseline recipe with `VRTSIM_CATB_STATS=1`.
**Gate:** 177.8 Mbps / MCS 28/28 reproduced AND the counter line appears in `ru.log`.
Combine time must be well under the 25 ms/slot wall budget — record the number, it is the
denominator for STEP 3's real-time gate.

---

## STEP 1 — DONE 2026-07-28 (PASSED)

**Gate:** 177.8 Mbps, MCS 28/28, PRACH 56.4 dB — bit-identical to STEP 0. Classification
`ref 21.2-21.4%` = **3 of every 14 symbols**, i.e. DMRS at 2/7/11 exactly as configured.

### THE FINDING — reads never align to symbol boundaries
**span-reads = 400000 / 400000 (100%).** A slot is 30720 samples but 14 reads of 2192 cover
only 30688, so reads drift 32 samples per slot and never re-align. Symbol 0 carries the long
CP (2224) while the rest are 2192, so fixed-size reads cannot land on boundaries.

**Consequence for STEP 3 (design change, not a detail):** a read CANNOT be classified
wholesale as reference-or-data. Each read must be **split at the symbol boundary** and its
two parts treated differently. Applying weights to a whole read would leak them onto DMRS
symbols and corrupt the very channel estimates that produce the weights — a self-reinforcing
error that would have presented as a smooth, plausible, entirely wrong degradation curve.

### METHOD ERROR (mine, recorded so it is not repeated)
The first Step-1 run failed outright (UE0 `synch Failed`, 0/2 attach, PRACH at the 20.7 dB
floor). To test whether the new code caused it I ran stats-on vs stats-off — **but shortened
`PER_UE_WAIT` 700->300 and `IPERF_SECONDS` 180->120 to save time.** Both arms then read
60 Mbps / MCS 0,23. The on-vs-off comparison was still valid (identical within 0.2%, so the
code is exonerated), but the absolute numbers were meaningless: `PER_UE_WAIT` scaling is a
known trap and 120 s is below the ~160 s MCS needs to converge. **Never change run
parameters in a run whose purpose is comparison against a baseline.** Re-running the exact
recipe gave the clean pass above.

---

## STEP 1 — symbol classification (functional no-op)

**Do:** teach vrtsim which symbols are reference symbols. Add
`VRTSIM_CATB_REF_SYMS="2,7,11"` (the 3 DMRS positions for our 13-symbol PUSCH).
Classify each symbol as REF or DATA in the UL path near `ul_combine_buffer`
(`vrtsim.c:262`, allocated `:825`). **Change nothing else** — both classes still take the
existing per-antenna path.

**Verify:** baseline recipe with the env set.
**Gate:** throughput bit-identical to STEP 0, and a debug counter shows exactly 3 REF and
11 DATA symbols per UL slot. If the counts are wrong, the symbol indexing is wrong — fix
here, where it is free, not in STEP 3 where it will look like a beamforming bug.

---

## STEP 2 — DONE 2026-07-28 (PASSED)

**Gate:** 177.5 Mbps / MCS 28/28 (baseline 177.8, within 0.2%) => export is passive.
Ring `/dev/shm/catb_weights` 273.1 KB, 9056 records published, one per (frame, slot, rnti)
with the two RNTIs alternating = one weight set per UL slot per UE.

### OAI HAS NO WEIGHT MATRIX TO EXPORT — STEP 2 had to COMPUTE it
`nr_ulsch_mmse_2layers()` builds the 2x2 Gram `H^H H` and applies its inverse to
matched-filtered data; the N_ant x 2 combiner is never materialised. So the DU now forms it
explicitly, per PRB: `G = H^H H + nvar*I`, `W = G^-1 H^H`. This is architecturally right
(R2.2 puts weight computation in the DU) but it is a real addition, not a tap.

New: `openair1/PHY/NR_TRANSPORT/catb_weight_ring.h` — header-only so DU and RU share one
definition with no build change. Seqlock per record (a torn set is never consumed),
`CATB_RING_DEPTH 8`, and `catb_ring_read(age_back)` deliberately exposes STALE records —
that is the mechanism STEP 3's `VRTSIM_BFW_DELAY_SLOTS` will use.
Published once per (frame,slot,rnti), not per symbol: the block runs on every data symbol
but the estimate is per slot, so per-symbol export would be 11x redundant hot-path work.

### The acceptance check I wrote was wrong; here is the right one
Planned: "per-antenna phase matches the configured CDL angles 0/90 deg." **Wrong by
construction** — MMSE weights are NOT steering vectors. `w_0 ~= P_perp(h_1) h_0`, so nulling
rotates the weight off the matched-filter direction, and CDL-A's angular spread destroys any
clean phase ramp (measured phase coherence 0.4-0.5, exactly what multipath gives).
What actually validates them:
| check | meaning | measured |
|-------|---------|----------|
| inter-layer correlation | 0 = the two layers point differently = separator works | **0.028-0.032** |
| adjacent-PRB correlation | <1 = frequency-selective; >>0 = smooth enough to sample at PRB centre | **0.91-0.96** |

---

## STEP 2 — DU exports its MMSE weights (passive, applies nothing)

**Do:** in `openair1/PHY/NR_TRANSPORT/nr_ulsch_demodulation.c`, at the existing MMSE-IRC
block (`:978-1003`, `OAI_UL_MU_IRC`), after the weights are formed, write them to a shared
ring under `OAI_CATB_WEIGHT_EXPORT=1`:
```
{ uint16_t frame, slot; uint8_t n_layers, n_ant; uint16_t n_prb;
  c16_t w[n_prb][n_layers][n_ant]; }   // 106 x 2 x 16 x 4 B = 13.6 kB/update
```
Simplest transport: a POSIX shm ring (same pattern vrtsim already uses), 8 slots deep.

**Verify:** baseline recipe with export on; dump the ring with a small reader.
**Gate:** (a) throughput unchanged — export is passive and must cost nothing measurable;
(b) one weight set per UL slot per UE; (c) weight magnitudes sane (no zeros, no clipping);
(d) the per-antenna phase pattern matches the configured CDL arrival angles 0 deg / 90 deg.
(d) is the real check that the weights mean what we think.

---

## Cat-B eAxC FIX 2026-07-28 — **BLOCKER CLEARED, Cat-B runs at Cat-A parity**

One line: `mask_ruPortId` 0x000f -> **0x00ff** for `XRAN_CATEGORY_B` (both the plain and
M-plane variants of `set_fh_eaxcid_conf`). Bits 4-7 were unallocated in that layout
(union 0xff0f, gap 0x00f0), so widening RU_Port_ID to 8 bits / 256 flows fills the hole and
**disturbs no other field** — no re-packing of cuPortId/bandSectorId/ccId.

| check | result |
|-------|--------|
| Cat-B active both ends | yes (du.log + ru.log) |
| negative `aarx` errors | **0** (was flooding) |
| attach | **2/2** |
| PRACH | **56.4 dB** |
| throughput | **177.8 Mbps @ MCS 28/28** = Cat-A baseline exactly |

Parity is the point: with beamforming untouched, Cat-B must change nothing. It doesn't.
The category switch is therefore a clean substrate for the C-plane BFW work.

Likely upstream-worthy: OAI's Cat-B RU_Port_ID mask is too narrow for ANY deployment whose
PRACH eAxC offset is >= 16, independent of this lab.

## Cat-B PROBE RESULT (superseded by the fix above) — how it failed

`OAI_XRAN_CAT=B` (new env override of the hardcoded `XRAN_CATEGORY_A` at `oran-config.c:1127`).
Confirmed active on both ends (message in du.log AND ru.log). Result: **attach 0/2, PRACH 0.0**
(not the 20 dB floor — zero, i.e. PRACH never processed at all).

**Root cause — the Cat-B eAxC ID layout cannot address our flows:**
```
Invalid PRACH C-plane config: ... aarx=-4  eAxC_offset=16
```
`aarx` is NEGATIVE. eAxC IDs decode to antenna via `eaxc - offset`, and:

| field | Cat-A | Cat-B | bits |
|-------|-------|-------|------|
| `mask_ruPortId` | **0x001f** | **0x000f** | 5 -> **4** |

Cat-B gives RU_Port_ID only 4 bits = 16 flows. We need **32**: 16 data eAxC (one per RX
antenna) + 16 PRACH eAxC at `eAxC_offset=16`. PRACH eAxCs 16-31 truncate to 0-15, so
`aarx = eaxc - 16` lands at -16..-1. Exactly the negative indices observed.

This is precisely what upstream warns about at `oran-config.c:1124`: *"each FH parameter is
hardcoded to CAT A... for CAT B, parameters of fh_init and fh_config structs must be modified
accordingly."*

**Fix is concrete, not open-ended:** widen `mask_ruPortId` for Cat-B (e.g. 0x00ff / 8 bits =
256 flows) and re-pack `ccId`/`bandSectorId`/`cuPortId` around it within the fixed 16-bit eAxC
ID. Both ends compute this identically from the same function, so they stay consistent.
**Do this BEFORE any weight plumbing** — the C-plane BFW path (R3.5) needs Cat-B, and Cat-B
needs working eAxC addressing first.

## 273 PRB RU HEADROOM 2026-07-28 (Cat-A baseline for the new target carrier)

Throughput **398.2 Mbps @ MCS 28/28**, PRACH 55.7 dB.
`combine avg 285.1 us, max 1124.2 us` over 389000 calls, `nsamps 4384` = one symbol at
122.88 Msps (double 106's 2192, confirming the sample-rate scaling).

Against the 1.786 ms per-symbol wall budget:
| | 106 PRB | 273 PRB |
|---|---|---|
| average | 10% | **16%** |
| worst case | 34% | **63%** |

RU-side MMSE adds ~32 complex MACs/subcarrier x 3276 subcarriers ~= 105k complex MACs/symbol.
Scalar Q15 (what the existing DL codebook kernel uses) projects to 200-400 us => **75-85%
worst case**. Feasible but thin, and RU overrun mimics latency degradation.
**Mitigation: SIMD the combine kernel** — the neighbouring Gram-matrix code is already
vectorised with SIMDe; 4-8x would drop MMSE to ~50 us. Do it in STEP 3, not after.

---

## STEP 3a IMPLEMENTATION CONTRACT (traced 2026-07-28) — exact API, both ends

### DU side (emit)
`xran_cp_populate_section_ext_1()` is **declared in the xran API and never called inside
xran** (`xran_cp_api.c:505` definition, `xran_cp_api.h:545` declaration, no internal callers).
It is an API the APPLICATION calls. Signature:
```c
int32_t xran_cp_populate_section_ext_1(int8_t *p_ext1_dst,     // destination buffer (we allocate)
                                       uint16_t ext1_dst_len,  // its size
                                       int16_t *p_bfw_iq_src,  // OUR weights, interleaved I/Q
                                       struct xran_prb_elm *p_pRbMapElm);
```
It reads these from `p_pRbMapElm->bf_weight` (so set them first):
| field | value for 3a |
|-------|--------------|
| `nAntElmTRx` | **16** (= `bfwNumPerRb`; source must hold `nAntElmTRx` complex int16 per RB, `len = nAntElmTRx*4` bytes) |
| `bfwIqWidth` | 16 to start (uncompressed), later the compression knob |
| `bfwCompMeth` | `XRAN_BFWCOMPMETHOD_NONE` (0) first; `BLKFLOAT` (1) works. **BLKSCALE/ULAW/BEAMSPACE `rte_panic()`** — do not select them |
| `numSetBFWs` | 0 or 1 => `numCPSections = 1`, i.e. ONE section = wideband. Exactly what 3a wants |
| `extType` | 1 |
Then set `bf_weight.p_ext_section` to the filled buffer and `ext_section_sz` to the returned
length so the C-plane builder includes it.
**Insertion point:** `radio/fhi_72/oaioran.c:1188-1210`, the `prbMap[idxElm]` loop that today
sets only `nBeamIndex`. Weights come from the STEP 2 ring (now an intra-DU handoff).

### RU side (consume) — easier than expected, no packet parsing
On C-plane receive xran stores the BFW for the application (`xran_cp_api.c:2756-2762`):
```c
prbMapElm->bf_weight.p_ext_start   = mbuf;      // and keeps it: *mb_free = MBUF_KEEP
prbMapElm->bf_weight.p_ext_section = section;   // -> the ext-1 content
```
So the RU **reads its own prbMap** rather than decoding packets. Apply at
`nr-oru.c:1183-1192`, between `nr_symbol_fep_ul()` and `write_pusch()`.

### Order of work for 3a
1. DU: allocate ext buffer + populate `bf_weight` + call the API. **Verify on the wire first**
   — C-plane packets must grow by ~`16 ant x 4 B` per section. Measurable with the DL-direction
   `ethtool -S` counters we already trust. Do NOT touch the RU until this is visible.
2. RU: read `bf_weight.p_ext_section`, log that weights arrive and match what was sent.
3. RU: apply to DATA symbols, `write_pusch` 2 layers instead of 16. **Gate: d=0 within 1%.**
4. Add `VRTSIM_BFW_DELAY_SLOTS` (ring already supports stale reads via `catb_ring_read(age_back)`).

---

## STEP 3 FEASIBILITY SPIKE 2026-07-28 — staged, and the first stage is much smaller than feared

**xran supports BFW on the wire, both directions.** TX builds ext-1 with the IQ appended to
the mbuf (`xran_cp_api.c:681-690`); RX parses it and points `extinfo->p_bfwIQ` at the payload
(`:2001`). The transport is not the problem.

**OAI wires NEITHER end.** The DU sets `nBeamIndex` only (index-based, Cat-A style,
`oaioran.c:1201`) and never `bf_weight`; the RU has no reference to `bf_weight`/`ext11`/
`sectionext` anywhere in `oaioran_ru.c` or `nr-oru.c`. Both sides are new integration.

**Constraint found: `XRAN_MAX_SET_BFWS = 1`** (`xran_fh_o_du.h:145`, with the original `(64)`
commented out). One BFW set per section. Per-PRB weights therefore need one section per PRB
or per bundle — a large multiplication of C-plane sections, or an xran rebuild.

### THE DE-RISK: the experiment does not need per-PRB weights
The deliverable is **throughput vs loop delay x UE speed**. Weight *staleness* is what we are
measuring; weight *granularity* affects absolute performance, not the shape of the staleness
curve. So stage it:

**3a — WIDEBAND weights, one BFW set per allocation.** Fits `MAX_SET_BFWS=1` and one section
naturally, no xran change, no section explosion. Proves the whole loop end to end: DU
populates `bf_weight` -> xran emits ext-1 -> RU reads `p_bfwIQ` -> applies at `nr-oru`'s
post-FFT point -> `VRTSIM_BFW_DELAY_SLOTS` makes it stale. **Gate: d=0 within 1% of the
Cat-A baseline.**
Step 2 measured adjacent-PRB weight correlation at 0.91-0.96, so wideband gives up real but
bounded accuracy — acceptable for a mechanism test, and quantifiable later.

**3b — per-PRB / per-bundle refinement.** Only after 3a's loop works. Either raise
`XRAN_MAX_SET_BFWS` (xran rebuild) or use ext-11 bundling across several sections. This is an
absolute-performance improvement, not a prerequisite for the experiment.

**3c — SIMD the combine kernel.** 273 PRB projects to 75-85% of RU budget with scalar Q15
(measured 63% before MMSE). The neighbouring Gram-matrix code is already SIMDe-vectorised.

### Apply point (correction carried from earlier)
`nr-oru.c:1183-1192`: `nr_symbol_fep_ul()` produces `rxdataF` per antenna per symbol, then
`write_pusch(rxdataF, aarx, ...)`. Combine 16 antenna FFTs into 2 layers there and call
`write_pusch` twice instead of sixteen. Frequency domain => PRB index falls out of subcarrier
index, symbol number is explicit, and **the 100% span-read problem disappears** (FFT boundary
IS the symbol boundary). This is why the apply belongs in `nr-oru`, not vrtsim.

---

## STEP 3 — REVISED 2026-07-28: weights travel the C-PLANE, not shared memory

**Requirement (user): every RU<->DU exchange goes over xran/FH.** DU->RU is the **C-plane
path** — so BFW rides section extension 1/11 on the existing UL C-plane messages, which the
DU already sends every slot to tell the RU what sections to expect. We are ADDING AN
EXTENSION to an existing message, not inventing a flow.

### What xran already provides (verified in-tree, no invention needed)
| facility | location |
|---|---|
| `XRAN_CP_SECTIONEXTCMD_1` = beamforming weights | `xran_cp_api.h:148` |
| `xran_sectionext1_info { rbNumber, p_bfwIQ, bfwIQ_sz }` | `:252` |
| **ext-11 per-PRB-bundle BFW**, own `bfwCompMeth` / `bfwIqWidth` | `:336` |
| receive-side decode `xran_sectionext11_recv_info` | `:364` |
| **`xran_prb_elm.bf_weight` / `bf_weight_update` / `BeamFormingType`** — per-PRB slot in the PRB map OAI ALREADY populates | `xran_fh_o_du.h:522` |
| BFW compression hooks | `radio/fhi_72/oai_bfp_compression.c:367` |

OAI's fhi_72 never sets `bf_weight`; only the compression stubs are wired. That gap is the work.

### The shm ring is NOT wasted — its role changes
`catb_weight_ring.h` was wrong as the DU->RU **transport**. But weights are computed in PHY
(`nr_ulsch_demodulation.c`) while the C-plane is built in the radio layer (`radio/fhi_72/`),
so an **intra-DU handoff across those layers is still needed**. The ring becomes that
internal staging buffer. Same code, different job; the seqlock and depth still apply.

### Revised STEP 3
1. **Prerequisite / first check:** `xranCat` must be `XRAN_CATEGORY_B`. This is NOT a local
   toggle — `set_fh_eaxcid_conf` (`oran-config.c:582`) gives Cat-B a DIFFERENT eAxC ID bit
   layout (`mask_ruPortId 0x000f`, `bit_cuPortId 12`...) than Cat-A, so eAxC addressing
   changes on both ends and every existing flow is affected. **Verify attach under Cat-B with
   weights untouched BEFORE any weight work** — one config change, one run. If the link does
   not come up in Cat-B mode, nothing downstream matters.
2. **DU:** PHY publishes W to the internal ring (STEP 2, done); the fhi_72 layer copies it
   into `xran_prb_elm.bf_weight` for the UL sections and sets `bf_weight_update`.
3. **xran** emits ext-1/ext-11 on the UL C-plane, inside the real `T1a_cp_ul` window
   (**285-535 us before the symbols it governs**, `du_test.conf:174`).
4. **RU:** take the decoded BFW from xran and apply to DATA symbols only; REF symbols stay
   per-antenna. Reads must be **split at symbol boundaries** (STEP 1: 100% of reads straddle).
5. **Delay knob:** loop latency is now PARTLY REAL (actual C-plane timing) with
   `VRTSIM_BFW_DELAY_SLOTS` layered on top to reach the sweep range.

### What this buys, beyond conformance
- **FH load accounting becomes real** — no synthetic BFW term; the bytes are on the wire.
- **R4.3 becomes testable.** With BFW on the C-plane, the ~250 us delivery window meets a
  fronthaul that adds 12.7 ms of queueing at its cap. The prediction that congestion breaks
  the CONTROL plane ~25x before the data plane can now be falsified. Over shm it could not.
- **BFW compression becomes a real knob** (`bfwCompMeth`/`bfwIqWidth`, ext-11). Same logic as
  the SRS discussion: BFW multiplies every data symbol, so it is the wrong place to save bits.

---

## STEP 3 — RU applies the weights, with a delay knob

**Do:**
1. Extend the Q15 kernel from `executables/nr-oru.c:600` (`apply_codebook_weights`) to the
   UL direction: `layer_out[l][re] = SUM_a W[prb][l][a] * ant_in[a][re]`, weights now
   **per PRB** rather than one set per symbol. Raise `ORU_CODEBOOK_MAX_NB_TX` 8 -> 16.
2. vrtsim reads the STEP 2 ring; applies weights to **DATA** symbols only; **REF** symbols
   stay per-antenna (that is what keeps the DU able to estimate).
3. `VRTSIM_BFW_DELAY_SLOTS=d` — apply the weight set from slot `N-d`. **d is in SLOTS, not
   microseconds**: at TS=0.02 a real 100 us FH delay is 2 us of sim time and would be
   invisible. One slot = 0.5 ms sim at 30 kHz.
4. Gate the whole thing on `VRTSIM_CATB_UL=1`; off = today's behaviour exactly.

**Verify:** baseline recipe, `VRTSIM_CATB_UL=1 VRTSIM_BFW_DELAY_SLOTS=0`.
**Gates:**
- (a) **d=0 within 1% of 177.8 Mbps** — if this fails, the receiver is wrong; do not proceed
  to the sweep, a broken receiver will produce a beautiful and meaningless degradation curve.
- (b) RU combine time still inside budget (compare against STEP 0's number). Cost is
  `16 x 2` MACs/RE x 1272 RE x 14 sym per slot in scalar Q15.
- (c) measured FH load drops to ~31% of 142 Mbps (~44 Mbps): 3 REF symbols at 16 antennas
  + 11 DATA symbols at 2 layers.

---

## STEP 4 — THE EXPERIMENT

**Sweep:** `d` = 0, 1, 2, 4, 8, 16, 32, 64 slots (0 - 32 ms sim)
x speed = 0, 3, 30, 120 km/h (`VRTSIM_UE_SPEED_KMH`).
Coherence time at 3.5 GHz: 3 km/h -> 43 ms | 30 -> 4.3 ms | 120 -> 1.1 ms.
Degradation predicted near `d ~ 0.1 x T_c`, i.e. ~8 slots @3 km/h, ~1 slot @30, immediate @120.

**Per point:** 180 s converged throughput, MCS, TBLER, weight age, per-layer SINR.
**N>=2 wherever the curve bends** — the intermittent per-UE fault has faked a result twice.
**Run an SU control arm** (`N_UE=1`): stale weights should hurt MU separation before SU gain,
so if SU and MU degrade identically, suspect a bug rather than physics.

**Deliverable:** degradation surface + max tolerable loop delay per speed.

---

## STEP 5-7 — SRS track (only after STEP 4 produces a curve)

- **5.** Enable SRS end to end: fhi_72 `srsEnable`/`srsEnableCp`, SRS eAxC config, extract/
  deposit path in `radio/fhi_72/oaioran.c` mirroring the PRACH path, vrtsim RU handling.
  `du_test.conf:18 do_SRS=0` -> 1. Known state: `do_SRS=1` alone runs but yields ZERO
  measurements (tested 2026-07-14). *Gate: non-zero SRS estimates at the DU for both UEs.*
- **6.** Source weights from SRS instead of DMRS; REF symbols no longer need forwarding, so
  FH drops to ~12.5% of Cat-A. *Gate: SRS- and DMRS-derived weights agree within ~1 dB
  combined SINR on a static channel.*
- **7.** Repeat STEP 4 with sounding period as a second axis. *Deliverable: does periodic
  sounding move the tolerable-latency bound versus continuously-available DMRS weights?*

---

## NEW FEATURE INVENTORY (what this plan actually adds)

### vrtsim — RU side (`radio/vrtsim/vrtsim.c`)
| # | feature | knob | step |
|---|---------|------|------|
| 1 | RU instrumentation: per-slot combine time (min/avg/max), weight age in slots | `VRTSIM_CATB_STATS=1` | 0 |
| 2 | Symbol classification REF vs DATA within the UL slot | `VRTSIM_CATB_REF_SYMS="2,7,11"` | 1 |
| 3 | **UL Cat-B master enable** — RU-side combining instead of DU-side | `VRTSIM_CATB_UL=1` | 3 |
| 4 | **Weight staleness knob, in SLOTS** (the experiment's independent variable) | `VRTSIM_BFW_DELAY_SLOTS=d` | 3 |
| 5 | Weight-ring consumer (shm reader + age tracking) | — | 3 |
| 6 | Per-PRB Q15 UL combining kernel, 16 antennas -> 2 layers | — | 3 |
| 7 | **Mixed-mode FH**: REF symbols at 16 streams, DATA symbols at 2 streams | — | 3 |
| 8 | SRS symbol handling on the RU FH path | — | 5 |

### OAI DU PHY (`openair1/PHY/NR_TRANSPORT/nr_ulsch_demodulation.c`)
| # | feature | knob | step |
|---|---------|------|------|
| 9 | Export MMSE-IRC weights (passive; applies nothing) | `OAI_CATB_WEIGHT_EXPORT=1` | 2 |
| 10 | Weight wire format `{frame, slot, n_layers, n_ant, n_prb, W[prb][l][ant]}` = 13.6 kB | — | 2 |
| 11 | shm weight ring, producer side, 8 deep | — | 2 |
| 12 | Weight computation sourced from SRS instead of DMRS | `OAI_CATB_WEIGHT_SRC=srs\|dmrs` | 6 |

### O-RU executable (`executables/nr-oru.{c,h}`)
| # | feature | step |
|---|---------|------|
| 13 | UL direction added to the Q15 kernel (today DL-only, `nr-oru.c:600`) | 3 |
| 14 | `ORU_CODEBOOK_MAX_NB_TX` 8 -> 16 | 3 |
| 15 | Explicit per-PRB weight storage alongside the 64-entry codebook | 3 |

### SRS enablement (`radio/fhi_72/`, `du_test.conf`)
| # | feature | step |
|---|---------|------|
| 16 | `srsEnable` / `srsEnableCp` in the fhi_72 config | 5 |
| 17 | SRS eAxC allocation | 5 |
| 18 | SRS extract/deposit path in `oaioran.c` (mirror of the PRACH path) | 5 |
| 19 | `du_test.conf:18 do_SRS = 0 -> 1` | 5 |

### Harness / analysis
| # | feature | step |
|---|---------|------|
| 20 | Sweep driver: delay x speed, 180 s runs, CN preflight, N>=2 at bends | 4 |
| 21 | Weight-age and per-layer SINR extraction from logs | 4 |
| 22 | SU control arm (`N_UE=1`) alongside the MU arm | 4 |

### Reused, NOT rebuilt
Q15 complex MAC kernel (`nr-oru.c:600`); logical-streams-vs-physical-antennas dual-buffer
passthrough pattern; env-gated-off-by-default discipline (`vrtsim.c:478`); the shm ring
pattern vrtsim already uses; `VRTSIM_UE_SPEED_KMH` (exists); FH load measurement via
`ethtool -S eno1np0 | grep port.tx_bytes`; the VF cap as an FH capacity knob.

**Totals: 6 new env knobs, 1 new IPC channel, 1 new signal-processing kernel, 4 SRS
integration points.** vrtsim currently has 19 env knobs; this adds 4 to it.

## Standing rules for every step

- Env-gated OFF by default; disabled path must be byte-identical to today.
- 180 s for any throughput claim, 60 s only for attach/PRACH.
- CN preflight before each run: `docker logs --since 5m oai-amf | grep -c "no SMF candidate"`;
  non-zero => `docker restart oai-smf oai-upf oai-amf`, wait 30 s.
- Failure triage: dead + PRACH ~20 dB = fronthaul; dead + PRACH ~56 dB = CN/attach, rerun.
- Build in `oaicicd/test_dir/openairinterface5g/build/` (NOT `cmake_targets/ran_build/build/`):
  `cd $OAI_DIR/build && ninja libvrtsim.so nr-softmodem nr-oru`.
