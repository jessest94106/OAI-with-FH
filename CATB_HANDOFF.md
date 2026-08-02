# Cat-B UL — SESSION HANDOFF (2026-07-28)
**Read this first.** Branch `catb-srs-ru-mmse` (pushed). Companions: `CATB_STEPS.md` (detail),
`CATB_REQUIREMENTS.md` (contract), `CATB_SRS_RU_MMSE_SCOPE.md` (why),
`CATB_SRS_COMPRESSION_PLAN.md`, `FIXED_NOISE_PRACH_LEDGER.md` (Cat-A ledger).

---

## 1. GOAL
Measure how **fronthaul latency in the beamforming weight loop** degrades performance, as a
function of UE speed. Deliverable = degradation surface (throughput vs loop delay x speed) plus
a maximum tolerable loop latency.

**Loop:** UE -> RU (16 ant) -> per-antenna reference symbols over FH -> DU channel estimate ->
DU weight computation -> **C-plane BFW back to RU** -> RU applies -> combined layers over FH.
Weights are always stale by `T_loop`; performance falls as that approaches coherence time
`T_c ~= 0.423/f_D` (3.5 GHz: 3 km/h -> 43 ms, 30 -> 4.3 ms, 120 -> 1.1 ms).

**Loop budget from OUR config:** `Ta3_up_min 200 us` + processing + `T1a_cp_ul_min 285 us` =
485 us minimum, against a 500 us slot at 30 kHz => **realistic loop is 1-2 slots**; sweep
interest is d=1-4, with 8-64 showing the asymptote.

---

## 2. STATE — what works, what does not

| Step | State |
|------|-------|
| Cat-A FH cliff | **DONE**, trustworthy (see ledger) |
| 0 instrument RU | **DONE** — combine 183-195 us avg / 568-618 max @106; 285/1124 @273 |
| 1 symbol map | **DONE** — 3-of-14 verified; **100% of reads straddle symbol boundaries** |
| 2 DU computes+publishes W | **DONE** — validated: inter-layer corr 0.03, adjacent-PRB 0.91-0.96 |
| Cat-B eAxC fix | **DONE** — `mask_ruPortId` 0x000f -> 0x00ff; Cat-B at Cat-A parity |
| **3a.1 DU emits BFW** | **DONE** — wire 7 -> 8 Mbps, attach 2/2, no crash |
| **3a.2 RU registers BFW rx** | **DONE** — buffers fixed, RU-only, verified attach 2/2 + 7 pools. The callback gate was IMPOSSIBLE: see §11. |
| 3a.3 RU applies weights | **NOT STARTED** — design below |
| 3b per-PRB, 3c SIMD | not started |
| **4 latency sweep** | **NO VALID DATA** — mechanism bug found, see §4 |
| **Cat-B attach** | **REGRESSED — blocks all of Step 3.** See §11. |

**Baseline for every gate:** 106 PRB w9, 2 UE, sigma=7 => **177.8 Mbps, MCS 28/28, PRACH ~56 dB**.
273 PRB baseline: **398.2 Mbps, MCS 28/28**.
**Re-measured 2026-07-28: Cat-A baseline reproduces at 174.8 sim Mbps, MCS 28/28, attach 2/2**
(60 s window, -1.7% vs reference). The tree and lab are healthy; the failure below is Cat-B only.

---

## 3. THE BIG LESSON (now in memory as `find-existing-caller-first`)
**Search the tree for a working caller before implementing against an unfamiliar API.**
3a.1 cost **7 attempts / ~3 h** reverse-engineering xran's BFW contract from the callee. A
correct caller existed all along in the sample app — copying it worked first try.
`xran_cp_populate_section_ext_1()` is declared in the API and **called from nowhere in the
tree**: an untested path whose failure mode is a segfault, not an error return.

Corollaries proven the hard way:
- When a component dies silently, check **`dmesg`** before inferring from absent app logs.
- Confirm the log you rely on is compiled in — xran's `print_err` is a no-op without
  `PRINTF_ERR_OK` (now enabled in `fhi_lib/lib/Makefile`; not pushable, it is O-RAN's repo).
- An **absent** error message proves nothing.

---

## 4. STEP 4 — mechanism is broken, root cause KNOWN
`OAI_CATB_DELAY_SLOTS=d` delays the channel estimate (weights derive from H, so delaying H is
equivalent and needs no FH involvement). Three sweeps + several controls all collapsed to
~2-3.5 Mbps, **flat across 1/4/16 ms**, which cannot be physical.

**ROOT CAUSE (found by checksum diagnostic):** ring keyed `ulsch_id % 8` while **`ulsch_id`
reaches 12** -> writes and reads land in different slots -> `view=(nil)` in every sample ->
**the delayed estimate was NEVER delivered**. Every "failure" was the block's own
`malloc`/`memcpy` cost in the decode path, not staleness.

**FIX (next session, ~1 line + cleanup):**
1. Key the ring by real decode identity — RNTI, or `ulsch_id` bounded by `gNB->max_nb_pusch`.
2. Move the copy off the per-slot hot path (it is ~1.8 MB/slot/UE at 16 ant).
3. **GATE: `view` must be non-nil in the `[CATB CK]` log.** Nothing is trustworthy otherwise.
4. **Static-channel control:** `d=8` at `VRTSIM_UE_SPEED_KMH=0` **must return ~177 Mbps** —
   a delayed estimate on a static channel is byte-identical, so the mechanism must be INERT.
   Only then run the sweep. Three sweeps were wasted by skipping this.

Sweep when green: d = 0,1,2,4,8,16,32 x speed 3/30/120 km/h, 180 s, N>=2, SU control arm.

---

## 5. STEP 3a.3 — design (reuse, do not invent)
`nr-oru.c:892` dispatches **one job per antenna** per symbol; each does
`nr_symbol_fep_ul` (FFT) -> rotate -> `write_pusch(aarx)`.

**Approach: change job granularity to ONE JOB PER SYMBOL** that FFTs all antennas internally,
combines with received weights, and calls `write_pusch` twice (layers) instead of 16 times.
- No atomic counter, no staging buffer, no join barrier.
- The **DL direction is the exact mirror** and already exists: `oru_north_read_thread` reads
  `nb_fh` streams and precodes to `nb_tx` antennas via `apply_codebook_weights`
  (`nr-oru.c:600`) — reuse that Q15 kernel, transposed.
- Weights arrive at `prbMapElm->bf_weight.p_ext_section` (xran deposits them; mbuf kept).
- Apply to DATA symbols only; REFERENCE symbols stay per-antenna (the DU cannot estimate the
  channel from combined data — that is the whole reason SRS exists in Cat-B).
- **Re-measure RU cost** (`VRTSIM_CATB_STATS`): 273 PRB is 63% of budget before MMSE; scalar
  Q15 projects 75-85%. SIMD (3c) may be required there. RU overrun mimics the effect under
  study — it has caused two false diagnoses already.
- **Gate:** throughput back to ~177 Mbps with BFW end-to-end. It is 0 today because sections
  are marked weight-based while no consumer exists.

---

## 6. ENV KNOBS ADDED (all default OFF)
| var | where | purpose |
|-----|-------|---------|
| `VRTSIM_CATB_STATS` | run_ru.sh | RU combine cost + symbol map counters |
| `VRTSIM_CATB_REF_SYMS` | run_ru.sh | reference-symbol positions (default 2,7,11) |
| `OAI_CATB_WEIGHT_EXPORT` | run_du.sh | DU computes + publishes W to shm ring |
| `OAI_CATB_BFW` | run_du.sh | DU attaches BFW to UL C-plane (3a.1) |
| `OAI_CATB_BFW_RX` | run_ru.sh | RU registers BFW reception (3a.2) |
| `OAI_CATB_DELAY_SLOTS` | run_du.sh | weight staleness in SLOTS (Step 4) |
| `OAI_XRAN_CAT` | both | force `XRAN_CATEGORY_B` |

**TRAP: both run scripts pass an explicit env allowlist (`sudo -E ... env VAR=...`). Unlisted
variables are dropped SILENTLY — the feature does nothing and the run looks healthy.**

---

## 7. BUILD TRAPS (each cost a wrong result)
- `oaioran.c` / `oran-config.c` live in **`liboran_fhlib_5g.so`**; `vrtsim.c` in
  **`libvrtsim.so`**. Building `nr-softmodem`/`nr-oru` rebuilds **neither**. `ninja
  oran_fhlib_5g` / `ninja libvrtsim.so`, and check mtime.
- Harness loads `oaicicd/test_dir/openairinterface5g/build/`, NOT `cmake_targets/ran_build/build/`.
- xran shared lib switch is **`XRAN_LIB_SO`**, not the `LIBXRANSO` that `build.sh` passes;
  needs `WIRELESS_SDK_TOOLCHAIN=gcc`, `RTE_SDK`, `XRAN_DIR` exported.
  Backup of the pre-debug library: `/tmp/libxran.so.backup_pre_debug`.

---

## 8. MEASUREMENT RULES (learned by getting them wrong)
- **180 s minimum** for any throughput claim; MCS converges at ~160 s. 60 s reads ~1/3.
- **Average over the last ~60 s**, not an 8-second tail — the tail alone produced ±13% spread;
  60 s windows repeat within ~1%.
- **CN preflight every run:** `docker logs --since 5m oai-amf | grep -c "no SMF candidate"`;
  non-zero => `docker restart oai-smf oai-upf oai-amf`, wait 30 s.
- **Failure triage by PRACH:** dead + ~20 dB = fronthaul; dead + ~56 dB = CN/attach, rerun.
- **Intermittent single-UE fault: ~1 in 3**, signature = one UE several MCS below the other,
  no PRACH/FH symptom. **Un-diagnosed, and the largest error term in any sweep.** Reject such
  runs on the MCS signal (independent of throughput) rather than averaging them in.
- Every new feature needs a log line proving it RAN. Four separate times a feature silently
  did not run while the test looked healthy.

---

## 9. FH FACTS (Cat-A, established)
- `wire_Mbps = floor(cap/50) x 50 x 1.03` — i40e quantises to 50 Mbps steps, +3% over.
- FH load is **traffic-independent** (IQ streams whether UEs send or not).
- `load_Mbps = 12.1 + 14.43 x iq_width` at 106 PRB; scales linearly with PRB count.
- TDD carries UL in **46/70 symbols = 65.7%**, which reconciles 32.52 Gb/s continuous-UL with
  21.6 Gb/s measured at 189 PRB.
- Congestion is a **wall, not a slope**: flat to 97% utilisation, total failure at 104%; the
  cliff moves with the cap. Failure is *erasure* (PRACH to the 20 dB floor), not degradation.
- BFW delivery window is only ~250 us wide (`T1a_cp_ul` 285-535 us) while a saturated FH adds
  **12.7 ms** of queueing => congestion should break the CONTROL plane ~25x before the data
  plane. **Untested prediction, now testable since BFW is on the wire (R4.3).**

---

## 10. NEXT SESSION, IN ORDER
1. **Verify 3a.2** — rerun with `OAI_CATB_BFW_RX=1`; the receive callback must fire.
2. **3a.3** — per §5. Gate: ~177 Mbps end-to-end.
3. **Fix Step 4 ring key** (§4), prove inert on a static channel, then sweep.
4. Optional/cheap: finish **189 w1-w16** (only w7-w12 exist: 309.6/310.0/310.2/285.3/310.5/258.1,
   never recorded in the ledger).
5. Root-cause the intermittent single-UE fault — it gates the credibility of every sweep.

---

## 11. SESSION 2026-07-28 (later) — 3a.2 buffers fixed; Cat-B attach REGRESSED

### What was fixed (built, in tree, all gated OFF by default)
1. **3a.2 passed the wrong buffers.** It handed `dstcp`/`srccp` to `xran_5g_bfw_config()` — the
   same two PRB maps already given to `xran_5g_fronthault_config()`. The sample app keeps **four**
   separate maps (`app_io_fh_xran.c:700-780`); OAI had two and used them twice. xran copies the
   argument into `sFHCpRxPrbMapBbuIoBufCtrl` (`xran_main.c:2135`) and writes received weight
   sections into it, i.e. into the live U-plane map. Now allocates dedicated maps via OAI's
   existing `oran_allocate_cplane_buffers()`, plus its own `bfw_tag`.
2. **Registration ran on the O-DU too.** Both `nr-softmodem` and `nr-oru` load `oran-init.c`
   (`ru_test.conf:52` has its own `fhi_72` block), and `sudo -E` passes the whole environment, so
   the run-script allowlist is not the only path. Now gated on `io_cfg.id` (O-RU only).
3. **RU `printf` never flushed.** stdout is block-buffered and the harness `pkill -9`s the RU, so
   `[CATB]` lines could vanish entirely. Added `fflush(stdout)`.

**Pool count is a log-independent oracle:** `grep -c xran_bm_init` = **5** feature off, **7** on.
Use it to confirm a flag took effect without trusting any log line.

### THE BLOCKER — Cat-B cannot attach (2 runs, reproducible)
| run | config | attach | crc_valid 1 |
|-----|--------|--------|-------------|
| 19:53 | Cat-B + BFW + BFW_RX | **0/2** | 0 |
| 20:19 | Cat-B + BFW, RX **off** | **0/2** | 0 |
| 20:45 | **Cat-A, all off** | **2/2** | 32, 174.8 Mbps, MCS 28/28 |

Signature: PRACH **detected** (`prach_I0` 24-25 dB, `PRACHPAIR DET`, RNTI assigned), then Msg3
dies — `rb 0+106 mcs 1 Qm 2 SNR ~7.0 dB, dtx 0, crc_valid 0, llr 0`. The DU sees energy and
demodulates to nothing. MCS 1 at 7 dB should decode essentially always => **corruption, not a
link-budget shortfall**. Zero successful UL TBs in ~2300 attempts.

**RESOLVED — ROOT CAUSE: stale `/dev/shm/catb_weights` surviving between runs.**
Full bisect: Cat-A 2/2 | Cat-B alone 2/2 | +WEIGHT_EXPORT 2/2 | **+BFW 0/2**.
The harness preflight deletes hugepages and `/dev/shm/vrtsim*`, but the Cat-B weight ring matches
neither pattern, so it persisted. `catb_bfw_attach()` (`oaioran.c:86-94`) retries the mapping
forever, so on every run after the first it mapped a PREVIOUS run's weights within the first UL
slots and attached BFW to every UL C-plane section (`oaioran.c:1273-1280` — no gate on UE state),
including Msg3. RA died, `llr 0`, attach 0/2.
**3a.1's original "attach 2/2" was real but first-run-only**: the file did not exist yet, and PHY
creates it only after both UEs connect. Every run since inherited it.
**FIX APPLIED:** `run_multi_ue.sh:51-56` now does `sudo rm -f /dev/shm/catb_weights` in preflight.
**VERIFIED 21:25 run:** attach **2/2**, `[CATB] UL C-plane BFW emission ON (ring mapped after
66001 attempts)` — i.e. BFW engages only after both UEs are up — then UL froze at 94001 B, MCS 0,0.
**That freeze is the expected no-consumer behaviour and is exactly what 3a.3 must fix.**
DURABLE FIX WORTH DOING: stamp the ring record with `XRAN_TIME_EPOCH` (already exported per run)
so emission ignores a ring it did not see created, instead of relying on preflight cleanup.

### Hypotheses FALSIFIED this session (do not re-run these)
- Buffer aliasing in 3a.2 causes the attach failure — **no**, fixed and it still fails.
- `MBUF_KEEP` retention causes it — **no**, RX-off control fails identically. (The mechanism is
  real and matters for 3a.3: `xran_cp_api.c:2751-2761`, registering BFW reception flips matching
  C-plane packets from free-after-parse to retained-until-overwritten. Retention is bounded by
  `N_FE_BUF_LEN x cc x ant x nPrbElm`, so size the pool before blaming it.)
- MU-IRC corrupting RA — **no**, `[MU GATE] g_mu=0` throughout; the guard held.
- `sectiondb_elm` overflowing `prbMap[]` — **no**, the reset at `xran_cp_api.c:2746` bounds `idx`
  to `nPrbElm` as long as the TX map is non-NULL, and OAI does populate `tx_prbmap`.
- CN — **no**, `no SMF candidate` = 0, all 10 containers up.

### NEW TRAP
**3a.2 may have no standalone gate.** Registering BFW reception is exactly what turns on mbuf
retention, so "callback fires AND attach 2/2" may be unreachable without 3a.3 consuming. Plan to
validate 3a.2 and 3a.3 together, or weaken 3a.2's gate to "callback fires".

### NEXT, IN ORDER
1. **Bisect the Cat-B attach failure** — `OAI_XRAN_CAT=B` alone, then `+WEIGHT_EXPORT`, then
   `+BFW`. Nothing in Step 3 is testable until Cat-B attaches.
2. Then 3a.2 + 3a.3 together (§5 design unchanged).
3. Gate for the whole of Step 3: back to ~175-178 Mbps, MCS 28/28, with BFW end-to-end.


---

## 12. 3a.2 IS DONE — and its original gate was unachievable

**`xran_5g_bfw_config()` (xran_main.c:2102-2153) declares `pCallback` and `pCallbackTag` and
NEVER REFERENCES THEM.** They are silently discarded; only `xran_5g_fronthault_config()` ever
populates `p_xran_dev_ctx->pCallback[]`. So "the receive callback must fire" — §10.1's first
instruction, and the thing two sessions chased — **could never happen in any run, with any
buffers, however correct the code**. Another dead path in the same class as
`xran_cp_populate_section_ext_1()` (§3): declared in the API, unexercised by the tree.

**What registration actually buys** (this part works): with the buffer lists installed,
`xran_cp_api.c:2751-2761` takes the `pRbMap != NULL` branch and deposits received weights at
`prbMapElm->bf_weight.p_ext_section`, retaining the mbuf (`*mb_free = MBUF_KEEP`).

**Verified 21:31 run:** attach **2/2**, RU `[CATB] BFW C-plane PRB maps allocated` +
`xran_5g_bfw_config -> 0 REGISTERED`, RU **7** pools, DU **5** pools (role gate working).

**CORRECT GATE for 3a.2 — and it is also 3a.3's first step:** a probe on the RU that reads its own
PRB map and reports whether `p_ext_section` is non-NULL and how many antennas' weights arrived.
Do that BEFORE writing the combining kernel. Do not add another callback-based check.

### Verified state of every knob (2026-07-28, all reproducible)
| config | attach | UL |
|--------|--------|-----|
| Cat-A, all off | 2/2 | **174.8 Mbps, MCS 28/28** |
| Cat-B alone | 2/2 | flowing |
| + WEIGHT_EXPORT | 2/2 | flowing |
| + BFW (3a.1) | 2/2 | **freezes when emission engages — 3a.3's target** |
| + BFW_RX (3a.2) | 2/2 | same |

**Pool-count oracle:** `grep -c xran_bm_init` = 5 feature off / 7 on. Log-independent, predates
the feature, cannot be defeated by stdout buffering. Use it to confirm a flag took effect.

---

## 13. 3a.3 — THE DESIGN IN §5 IS WRONG FOR THIS RU. Probe PASSED.

**`nr-oru` parses C-plane ITSELF and never reads xran's PRB-map deposit.**
`oaioran_ru.c:825-913` handles `XRAN_CP_SECTIONTYPE_1` directly off the mbuf, fills
`pusch_config[aarx][slot][symbol]`, and returns `MBUF_FREE`. So
`prbMapElm->bf_weight.p_ext_section` — what §5 assumed and what 3a.2 registered — is **not the
path weights take to this RU**. (`nr-oru`'s own banner says it is not a real 7.2 O-RU.)

**Weights arrive as an ext-1 appended to the section the RU already parses**, flagged by
`section->hdr.u.s1.ef`. Read them there. No `xran_api` accessor needed, no cross-module plumbing.

**PROBE ADDED + PASSED** (`oaioran_ru.c:902`, gated `OAI_CATB_BFW_RX`, read-only — deliberately
does NOT `rte_pktmbuf_adj`, so the U-plane path is untouched):
```
sections=102157 with_ef=10001 | extType=1 extLen=17 compMeth=0 iqWidth=0 | aarx=12 slot=1 sym=10 prb=0+106
```
- `extType=1` = BFW. `extLen=17` words = 68 B = 4 B hdr + **16 ant x 4 B**. `compMeth=0`
  uncompressed, `iqWidth=0` = 16-bit. Exactly what the DU sends for 16 antennas.
- Steady-state **25% of UL sections carry BFW** ((10001-8001)/(102157-94157)); the cumulative
  ratio is lower only because counting starts before emission engages.
- attach **2/2** with the probe in.

**Consequence for 3a.2:** its registration is correct but probably **INERT on this RU** — nothing
here consumes xran's deposit. The fixes were still real (aliasing, wrong-side registration) and
attach is 2/2, but do not expect 3a.2 to be load-bearing.

### REMAINING WORK FOR 3a.3 (the combine kernel)
1. Parse the ext-1 BFW IQ into a per-(aarx,slot,symbol) weight store, beside `pusch_config`.
   Bytes start at `section + sizeof(xran_cp_radioapp_section1) + sizeof(ext1 hdr)`; 16 x (I,Q) int16.
2. Restructure `nr-oru.c:892` from one job per ANTENNA to one job per SYMBOL (§5 approach is
   still right here): FFT all antennas, combine to 2 layers, `write_pusch` twice not sixteen times.
3. Reuse `apply_codebook_weights` (`nr-oru.c:601`) transposed — Q15 complex MAC, already written.
4. REFERENCE symbols stay per-antenna (default 2,7,11 via `VRTSIM_CATB_REF_SYMS`).
5. Gate: **~175-178 Mbps, MCS 28/28** with BFW end-to-end (Cat-A re-measured at 174.8).
6. Then `VRTSIM_CATB_STATS` to decide whether 3c (SIMD) is needed. At 106 PRB headroom was
   ~34% worst case, so 3c is likely skippable; 273 PRB is the case that forces it.

---

## 14. 3a.3 COMBINE KERNEL RUNS (2026-07-28 23:01) — blocked on DU-side eAxC

**First run in which the RU actually combined antennas.**
```
[CATB UL] ref=13044 combined=819 no_weights=46138
[CATB BFW RX] ... n_ant=16 seq=2501 w[0..3]=(1986,-208)(-1553,-6990)
attach 2/2 | sum_lcid4 frozen 46233 B | MCS 0,0 | no segfault
```
- Weights decode to real Q15 values, varying per antenna. Not zeros, not garbage.
- `combined=819` = the kernel executed. Mechanism proven.
- UL freezes once combining engages. **Expected**: the RU sends 1 stream on DATA symbols while
  the DU is configured for 16 UL eAxC. This is the fork-(b) work, not a bug in the kernel.

### IMPLEMENTATION AS BUILT (all default OFF)
| file | what |
|------|------|
| `oaioran_ru.c` | `catb_bfw[20][14]` store + `catb_bfw_get()`; ext-1 decode at the section parser, stored for EVERY symbol the section covers |
| `common_lib.h` | `read_bfw` added to `xran_api` |
| `oran_isolate.c` | `read_bfw = catb_bfw_get` |
| `nr-oru.c` | `receive_pusch_catb()` per-symbol job; `catb_combine_ul()` Q15 `w^H x`; dispatcher branches on `VRTSIM_CATB_UL` |
| `run_ru.sh` | `VRTSIM_CATB_UL` added to the env allowlist |

**Buffer placement (three attempts, only the third works):** 16 ant x 4096 RE x 4 B = 256 kB.
VLA on the stack overflows the tpool worker stack; `static __thread` of that size overflows the
STATIC TLS BLOCK and kills thread creation at RU startup. Correct: a `__thread` POINTER plus one
`aligned_alloc` per worker, never freed.

### **BUILD TRAP THAT COST 3 RUNS — §7 IS RIGHT, I IGNORED IT**
`read_bfw` went into `xran_api` INSIDE `openair0_device`, so the struct layout changed. FOUR
artifacts embed it: `nr-oru`, `liboran_fhlib_5g.so`, **`libvrtsim.so`**, **`nr-softmodem`**.
Rebuilding only the first two left vrtsim reading `openair0_device` at stale offsets ->
`ru_thread` segfault right after vrtsim's own "Channel model server_tx_channel_model" log line.
**The fault address never changed across three different buffer strategies — that was the tell.**
Guard, one command after any header change:
```
ls -l --time-style=+%H:%M:%S nr-softmodem nr-oru liboran_fhlib_5g.so libvrtsim.so
```
Consider avoiding `openair0_device` entirely: a Cat-B accessor passed at registration has no ABI
blast radius.

### RESOLVED — the weights DO update
Across the 23:01 run the decoded vectors took distinct values:
`(1986,-208)(-1553,-6990)` and `(1773,72)(-1929,-7869)`. `catb_publish_weights()` is called once
per (frame, slot, rnti) at `nr_ulsch_demodulation.c:1471`, so the ring refreshes every slot; the
repeats seen earlier were just a slow channel (CDL_A, 1.5 m/s, TS=0.02) sampled every 2000
sections. **The weight loop is live.**

### NEXT (the fork-(b) work)
1. DU: accept **variable eAxC per symbol** — 16 on reference symbols (2,7,11), 1 (later nLayers)
   on data symbols. `neAxcUl` is currently a single config value on both sides.
2. Then 2 layers: DU must emit PER-LAYER BFW on distinct eAxC (`oaioran.c` hardcodes layer 0),
   and `receive_pusch_catb` calls `write_pusch` once per layer.
3. Gate: ~175-178 Mbps, MCS 28/28 (Cat-A re-measured 174.8).
4. `VRTSIM_CATB_STATS` then decides 3c. At 106 PRB headroom was ~34% worst case, so 3c likely
   skippable; 273 PRB is the case that forces it.

### DU-SIDE DESIGN (analysed 2026-07-28, NOT yet implemented)
Two parts, and they are indivisible — plumbing alone cannot be tested because nothing decodes.

**Part 1 — plumbing (`oaioran.c:735-750`).** The UL copy-out loops `ant_id < ru->nb_rx` (16) for
every UL symbol and copies `bufs->dst[ant_id]` into `ru->rxdataF[ant_id]`. On DATA symbols only
eAxC 0 now carries data, so antennas 1-15 stay zero and `[UL SYM MISS]` fires 15x per symbol.
`ul_eaxc` already exists (`oaioran.c:193-197`, "neAxcUl under asymmetric eAxC") — extend it to be
per-symbol rather than per-slot.

**Part 2 — effective channel in PHY.** This is the real work. The DU estimates `H` (16x1) from
the per-antenna REFERENCE symbols, but the DATA symbols it receives are already combined:
`y = w^H x`. The existing equaliser would apply a 16-antenna `H` to a 1-stream `y`.
**Key point: the DU needs NO extra fronthaul to fix this — it already knows `w`, because it
computed and published it.** So it can build the effective 1-antenna channel locally:
```
h_eff[re] = sum_a conj(w[a]) * H[a][re]
```
and run a 1-antenna receiver on data symbols. No extra IQ on the wire, no new C-plane.

**RISK:** `nb_antennas_rx` is threaded through the whole slot-processing path, so "1 antenna on
data symbols, 16 on reference symbols" is invasive and can break the working Cat-A path. Gate it
hard behind its own env var and re-run the Cat-A baseline (174.8 Mbps, MCS 28/28) as a control.

**SCOPE REMINDER before spending days here:** Step 4 does NOT require any of this. Delaying `H`
inside the DU is mathematically equivalent to delaying `W` (§4), so the latency surface can be
measured with the ring fix alone. Step 3 buys external validity (the delay is imposed by the real
485 us budget rather than typed in), the 87.5% UL FH reduction, and the §9 C-plane congestion
test — not the deliverable itself.

---

## 15. DU RECEIVE MODE BUILT — loop closed in code, does not decode yet (2026-07-29)

### What now exists (all gated OFF by default)
| knob | side | effect |
|------|------|--------|
| `VRTSIM_CATB_UL=1` | RU | per-symbol job; DATA symbols -> 1 combined stream, REFERENCE symbols -> 16 antennas |
| `OAI_CATB_UL_RX=1` | DU | `nb_rx_ant` becomes EFFECTIVE: 1 on data symbols, 16 on reference symbols |

**DU implementation** (`nr_ulsch_demodulation.c`): `nb_rx_ant` is switched to 1 on Cat-B data
symbols so every VLA and downstream call sizes consistently; `nb_rx_ant_true` is kept ONLY for
indexing `pusch_vars->ul_ch_estimates[aatx * nb_rx_ant_true + a]` (using the effective count there
would silently read the wrong layer's estimates). A new extraction branch builds
`h_eff = sum_a conj(w[a]) * H[l][a]` via `catb_read_last_weights()`, which reads back the same
wideband mid-band-PRB layer-0 vector `oaioran.c catb_bfw_attach()` puts on the wire.
**No extra fronthaul is needed** — the DU already knows `w`, it published it.

### Verified working
- attach **2/2** in every Cat-B configuration; 32 CRC-OK TBs (the attach TBs).
- RU combining executes: `combined=9824..10940` per 20k-symbol window.
- Both sides agree on the reference mask (`0x0884` = symbols 2,7,11), which matches the type-A
  13-symbol allocation (`sym 0+13`, l0=2, addpos=2) — NOT a mismatch, checked.
- Math is consistent: RU computes `y = w^H x`, DU computes `h_eff = w^H H`, so `y = h_eff*s`.
  Both conjugate the weight; verified by reading both kernels.

### STILL FAILING: 0 Mbps, MCS 0,0 with combining active
Attach succeeds because it happens BEFORE weights flow, when both sides use the same degenerate
weight (antenna 0, unit). Once real weights engage, nothing decodes.

### Two bugs found and fixed on the way (both real, neither sufficient)
1. **Weight store keyed too strictly.** `catb_bfw[slot][symbol]` only got entries for the ~25% of
   UL sections carrying an ext-1, so the RU fell back to per-antenna on ~98% of data symbols while
   the DU treated all of them as combined. Fixed with a `catb_bfw_latest` fallback -> combined
   went 912 -> 10940.
2. **Framing derived from different predicates on each side.** RU used "do I have weights for this
   (slot,symbol)?", DU used "is this a data symbol?". Both individually reasonable, jointly wrong.
   Fixed: RU now ALWAYS sends 1 stream on data symbols, emitting antenna 0 alone when it has no
   weights — exactly the degenerate weight the DU's fallback assumes.

### REMAINING CANDIDATES, most likely first
1. **Weight-vintage mismatch.** The RU applies the weights that arrived over the C-plane
   (fronthaul-delayed); the DU builds `h_eff` from the NEWEST ring entry. Different vintages.
   Benign-looking at 1.5 m/s but this is exactly the staleness under study. **Fix: key weights by
   slot on both sides so the DU equalises with the vintage the RU actually applied.**
2. **Q15 saturation.** Both kernels do `>>15` per term then sum 16 antennas and saturate to int16.
   Observed weight magnitudes are 1500-7900 (0.05-0.24), so a 16-term sum can exceed full scale.
   Instrument the pre-saturation accumulator before assuming the algorithm is wrong.
3. **`log2_maxh` / output_shift** is computed for a 16-antenna sum; at 1 effective antenna the
   scaling assumption changes and LLRs may be crushed or saturated.

### CAT-A REGRESSION CONTROL: **PASS** (2026-07-29 00:29)
`attach 2/2 | 174.0 sim Mbps | MCS 28,28` (60 s window), vs 174.8 before the DU receiver change
and 177.8 reference. Within the +/-1% repeat band. **`nb_rx_ant` switching did NOT disturb the
working Cat-A path** — every Cat-B knob defaults off and the default path is byte-identical.

### NEXT DIAGNOSTIC (cheap, do this before more runs)
Log, for one data symbol: `|y|` at the RU after combining, `|h_eff|` at the DU, and the LLR
magnitude. That separates saturation (2) from vintage mismatch (1) from scaling (3) in ONE run,
instead of a 20-minute run per hypothesis.

---

## 16. STEP 4 MECHANISM VALIDATED (2026-07-29 01:24) — first time ever

### §4.4 INERT GATE: **PASS**
`OAI_CATB_DELAY_SLOTS=8 VRTSIM_UE_SPEED_KMH=0 VRTSIM_RX_NOISE_SIGMA=0`
-> **167.2 Mbps, MCS 28/28, attach 2/2**, `view` non-nil, partner checksum healthy.

### TWO ring-key bugs fixed (both required; neither sufficient alone)
1. **`ulsch_id % 8` aliasing.** `gNB->max_nb_pusch = 144` here, so 18 distinct decodes folded onto
   each ring slot. Symptom: `view=(nil)` in every sample.
2. **`ulsch_id` IS NOT A UE IDENTITY.** It is a rotating index into the decode-slot pool,
   reassigned per grant, so the same UE gets a different `ulsch_id` every slot. Keying by it wrote
   each entry once and never accumulated history. Symptom: `view` non-nil but partner checksum ~0
   (`self=12401 partner=8`). **Now keyed by RNTI** (`catb_ue_slot()`), writer by `rel15_ul->rnti`,
   reader by the PARTNER's rnti captured in the partner scan.
   -> partner checksum went 8 -> 50665 (self 78412). Real data delivered at last.
3. **Self leg now delayed too.** `W = f(H_self, H_partner)`; delaying only the partner modelled
   half the staleness, so "delaying H == delaying W" did not hold.

### **THE GATE ITSELF WAS MIS-SPECIFIED — correct §4.4 before reusing it**
§4.4 said "a delayed estimate on a static channel is byte-identical, so the mechanism must be
INERT". That is only true with **NO NOISE**. At `sigma=7` the estimate is `H + n(t)`, so a delayed
one carries an UNCORRELATED NOISE REALISATION even at 0 km/h. The inert control REQUIRES
`VRTSIM_RX_NOISE_SIGMA=0` as well as `VRTSIM_UE_SPEED_KMH=0`. Without it a perfectly correct
mechanism reads as broken forever.

### OPEN — noise-decorrelation confound, decide before sweeping
Same `d=8` at 0 km/h: **sigma=0 -> 167.2 Mbps** but **sigma=7 -> 7.2 Mbps**. At 0 km/h the channel
does not age, so that entire collapse is estimate-NOISE decorrelation, not channel aging. MU-IRC
nulling of two co-scheduled UEs is evidently very sensitive to it.
**Consequence for the sweep:** throughput(d) at `sigma=7` mixes two effects — channel aging (what
we want) and estimate-noise decorrelation (an artifact of delaying a noisy estimate). Options:
 (a) normalise every point to the d=0 arm AT THE SAME SPEED, or
 (b) run the sweep at sigma=0 so only channel aging varies, or
 (c) characterise the noise-only penalty at 0 km/h across d and subtract it.
Do NOT sweep at sigma=7 and read the result as coherence-time physics.

### Still to do before the sweep
- Matched control `d=0, speed 0, sigma 0` to confirm 167.2 is full rate at sigma=0 (MCS 28/28
  strongly suggests it is).
- `VRTSIM_UE_SPEED_KMH` was NOT in any run-script allowlist (§6 trap) — now added to `run_ru.sh`.
  It is still NOT in `run_ue.sh`; check whether the UE side needs it before trusting a speed sweep.

---

## 17. STEP 3 FIRST DECODE (2026-07-30) — 0 -> 3.1 Mbps. Six more bugs, one big lesson.

**Result: 3.1 Mbps, MCS 7,0** (target ~174). First time the Cat-B combined path decoded ANYTHING.

### Bugs found and fixed this round, in order
1. **Dependency cycle.** Weight computation lived inside the MU-IRC block, whose gate needs
   `nb_rx_ant >= 2`. Cat-B sets `nb_rx_ant = 1` on data symbols -> IRC never engages -> no weights
   -> no combining -> no throughput -> `g_mu_mimo_active` goes 0 -> even more locked out.
   FIX: standalone weight computation on DMRS symbols, gated on nothing but "both UEs have an
   estimate stamped for this slot". Independent of `g_mu_mimo_active` and `log2_maxh`.
2. **Vintage hack removed** (`catb_bfw_latest`, `catb_read_last_weights`). Both sides now key
   weights by the section's slot via a new seqlocked `applied[20]` table in the shm ring.
3. **THE REFERENCE SYMBOLS WERE WRONG.** Hardcoded 2,7,11. Measured `dmrs=0` at 2 and 7; the real
   DMRS mask is **0x0421 = symbols 0, 5, 10**. So the RU forwarded 16 antennas on PILOT-FREE
   symbols while COMBINING the ones carrying DMRS — destroying the DU's channel estimate, which
   is why every published weight was zero (`self_sum` 0 or 8 instead of ~1e6).
   FIX: PHY publishes `ul_dmrs_symb_pos` into the ring; the fronthaul layer (which has no PUSCH
   PDU) reads it and attaches BFW to DATA symbols only. **The RU then decides purely on weight
   presence — O-RAN's `ef` bit carries the framing, so the two sides cannot disagree.**
   `VRTSIM_CATB_REF_SYMS` is dead as a correctness knob.
4. **Weight-validity gate too weak** — `s0sum > 0` let a channel sum of 8 (noise) publish garbage.
   Now `> 1000`; a real channel is ~1e6.
5. **RE stride** — `catb_publish_weights` hardcoded `re = prb*12+6`, valid on data symbols but
   DMRS symbols pack only 6 REs/PRB. Now takes `re_per_prb`.
6. **BFW not normalised.** MMSE weights `w = (H^H H + nvar I)^-1 h` are unnormalised; measured
   |w| ~ 0.7 in Q15 per antenna. The RU sums 16 such terms and saturates int16 -> every sample
   clipped. FIX: rescale to `sum(|I|+|Q|) <= 32767` in `catb_bfw_attach`, BEFORE both the ext-1
   and `catb_applied_write`, so wire and `h_eff` share the identical vector. Only the DIRECTION of
   w matters (a common scale cancels between `y = w^H x` and `h_eff = w^H H`), so this is free.

### THE LESSON THAT ACTUALLY MATTERED
Every diagnosis made by READING code and inferring was wrong (vintage, RE stride, buffer
placement, noise decorrelation — four in a row, ~25 min each). Every diagnosis made after logging
an actual VALUE was right. The two decisive fields were `self_sum/partner_sum` (found the wrong
DMRS symbols) and `w[0..3]` (found the zero weights, then the saturation). **Log magnitudes, not
presence flags.** `n_ant=16` looked healthy the entire time the vector was all zeros.

### STILL OPEN — the 3.1 vs 174 Mbps gap
- **Coverage:** RU `combined=4713 / no_weights=89201` — only ~5% of data symbols get weights. A TB
  whose symbols are partly combined and partly per-antenna mixes two effective channels and dies.
  Find why 95% of data symbols still have no ext-1.
- **Zeros still appear on the wire** in sampled sections (`w[0..3]=(0,0)`) — some slots publish
  nothing. Likely the same coverage issue.
- **Asymmetric MCS 7,0** — one UE decodes, the other does not. Suspect the single-layer limitation:
  only layer 0's weights are ever emitted (`oaioran.c` hardcodes layer 0), so UE1 has no beam.
- **Wideband vs per-PRB:** 3a uses one vector for the whole allocation; Step 2 measured
  adjacent-PRB weight correlation 0.91-0.96, so expect a real but bounded loss even when correct.
- **Global DMRS mask:** observed `0x0400` then `0x0421` — different PDUs carry different DMRS
  configs. The ring holds ONE mask, last-writer-wins. Fine for 2 symmetric UEs, wrong in general.

### NEXT (do these in order, and MEASURE first)
1. Instrument WHY 95% of data symbols lack an ext-1 — count `catb_bfw_attach` early-returns by
   reason (ring unmapped / ring_read fail / dmrs skip). One run, decides everything else.
2. Then per-layer BFW so UE1 gets a beam (currently layer 0 only).
3. Only then chase the remaining gap to ~174.

---

## 18. COVERAGE BUG LOCATED BY CENSUS (2026-07-30) — slot-key mismatch, NOT the DU

### The census (add counters to every exit path — this is what finally located it)
`[CATB ATTACH] calls=160000 off=0 nomap=30000 dmrs_skip=32500 read_fail=24828 attached=72672`
Steady-state deltas over the last 40k calls: **nomap=0, read_fail=0, dmrs_skip=25%, attached=75%.**
=> **The DU weight pipeline is HEALTHY.** Ring mapping and seqlock reads were both suspects; both
are now excluded by measurement rather than by inspection.

### The loss is downstream, in two stages
| stage | rate |
|-------|------|
| DU attaches BFW | **75%** of sections |
| RU sees `ef` on the wire | 26001/167297 = **15.5%** |
| RU actually combines | 4758/93914 = **5%** |

**Stage 1 (75% -> 15.5%) IS UNDERSTOOD:** the DU's PRB map is per **(antenna, SLOT)**, not per
symbol. `catb_bfw_attach` is called inside a symbol loop, so all 14 calls land on the SAME
`pRbElm` and overwrite each other's `bf_weight` — only ONE ext-1 per element survives to the wire
per slot. Any future per-symbol beamforming (3b) needs multiple prbMap elements or ext-11
bundling, not more calls to the same element.

**Stage 2 (15.5% -> 5%) IS NOT FIXED.** A same-slot lookup was added to `catb_bfw_get()` (use any
symbol of the SAME slot — exact, not an approximation, because 3a publishes one wideband vector
per slot and every symbol in slot N shares one vintage). It did NOT move coverage:
`combined=4758 no_weights=89156`, unchanged.

### PRIME SUSPECT for stage 2 — slot-key mismatch under timescale dilation
The RU STORES weights under the slot parsed from the C-plane header
(`hdr->cmnhdr.field.slotId + subframeId * (1 << mu)`, `oaioran_ru.c` section-1 parser) but LOOKS
THEM UP under the RU's own free-running air slot in `receive_pusch_catb`. **`oaioran_ru.c` already
documents this exact hazard for PRACH:** "under XRAN_TIMESCALE dilation the DU's xran SFN is
GPS-second-anchored while the RU's vrtsim air frame free-runs, so the two frame counters drift and
the frame key won't match" — and it carries a `prach_config_latest_by_slot` fallback for it.
Cat-B has no equivalent. TS=0.02 means we are always under dilation.
**Next action: log both keys side by side for the same section (stored slot vs lookup slot) —
one run, and it either confirms the drift or eliminates it.** Do NOT infer; measure.

### Status
- Cat-B end-to-end: decodes (0 -> 3.1 Mbps in the previous run), still far below the ~174 target.
- This run: attach 2/2, 0.0 Mbps — coverage still 5%, so partial TBs still dominate.
- Cat-A regression control: unaffected, every knob defaults off.

### Two operational errors cost ~50 min (do not repeat)
1. `bash run_multi_ue.sh ... &` chained INSIDE an already-backgrounded call orphans the run; the
   log dir is created then stays EMPTY. One long-running action per invocation.
2. Purging hugepages 1 s after killing the previous run makes the next `rte_eal_init` panic
   (`xran_ethdi_init_dpdk_io -> __rte_panic`). Reproduce the harness ordering: kill, WAIT ~4 s,
   then purge `/dev/hugepages`, `/dev/shm/vrtsim*`, `/var/run/dpdk`.

---

## 19. COVERAGE ROOT CAUSE — C-plane is PER-PERIOD, not per-slot (2026-07-31)

### Slot-key census: keys do NOT drift. The distributions align exactly.
```
[CATB KEY store]  per-slot: 0,5008,0,0,0, 0,5008,0,0,0, 0,4993,0,0,0, 0,4992,0,0,0
[CATB KEY lookup] hit/ask:  0/0,1580/2608,0/9128,0/9128,0/9128, 0/0,1580/2608,...
```
Weights are stored ONLY at slots **1, 6, 11, 16** — the FIRST UL slot of each TDD period.
Slots 2,3,4 / 7,8,9 / ... are asked **9128 times each and hit 0**.
4 stored slots x 2608 asks ~ 10k of ~93k total = **exactly the observed 5% coverage**.

### The DU is NOT the problem — measured, twice
`[CATB ATTACH] calls=160000 off=0 nomap=30000 dmrs_skip=32500 read_fail=26892 attached=70608`
`read_fail` is FROZEN (the §19 cache works), `attached` ~75%. The DU attaches BFW across all UL
slots. **The RU still only ever receives them for 1, 6, 11, 16.**

### ROOT CAUSE
**The UL C-plane is emitted ONE SECTION PER TDD PERIOD, whose header carries the FIRST UL slot of
that period and which covers the period's whole UL allocation.** The RU parses
`slot = hdr->cmnhdr.field.slotId + subframeId * (1 << mu)` and stores under that single slot, so
slots 2,3,4 never get an entry no matter what the DU attaches. This also explains §18's
"75% -> 15.5% on the wire": most attach calls write a `bf_weight` that is never separately
transmitted, because there is no separate section for those slots.

### THE FIX (RU side, not yet implemented)
`catb_bfw_get(slot, symbol)` must resolve to the **period's first UL slot**, not the exact slot:
the section that carried the weights is scoped to the PERIOD. With `nTddPeriod = 5` and UL slots
1-4, slots 2,3,4 must read the entry stored at slot 1. This is exact, not an approximation — it is
the same C-plane section, so the same vintage. Derive the period start from
`fh_cfg->frame_conf.nTddPeriod` rather than hardcoding 5.
Expect coverage 5% -> ~63%; the residual is §18's per-symbol overwrite (measured 1580/2608 hits
even on stored slots), which needs multiple prbMap elements or ext-11 bundling (3b).

### What was fixed this round (correct, keep it)
`catb_bfw_attach` now CACHES the last good ring record. PHY writes the ring during DECODE once per
(frame,slot,rnti), but the C-plane for every UL slot of a period is built BEFORE those decodes:
production is 1 record/period, consumption needs 1 per UL slot. Requiring a same-slot record
modelled a zero-delay loop, which cannot exist — §1's budget forces 1-2 slots of staleness.
Vintage is preserved: `rec.frame/rec.slot` flow into `catb_applied_write()`, so the DU still
equalises with exactly the vector the RU applied and the true age is recorded.

---

## 20. COVERAGE SOLVED (5% -> 100%). Throughput still 0 — production deadlock found (2026-07-31)

### §19's fix works, and beats its own prediction
`catb_bfw_get()` now resolves the lookup slot to the period's FIRST UL slot, derived from
`fh_cfg->frame_conf.nTddPeriod` + `sSlotConfig[].nSymbolType[]` (`catb_period_first_ul_slot()` in
`oaioran_ru.c`, shared with the DU side via `oaioran_ru.h`). Proof it ran, on both DU and RU:
`[CATB BFW] period scoping: nTddPeriod=5 first_ul_slot_in_pattern=1` — matching the measured store
slots 1,6,11,16 exactly, and derived rather than hardcoded.

Per-slot lookup went `0/9128` -> `5754/9128` on precisely the three dead slots.

### Coverage is 100%, not the predicted 63% — read the census as DELTAS, not totals
The `[CATB UL]` census is CUMULATIVE, so its final line understates steady state. Differencing
consecutive prints (no new run needed — the data is already in `ru.log`):
```
dcomb=0      dnow=15652   coverage=0.0%     <- pre-traffic
dcomb=10093  dnow=5559    coverage=64.5%    <- first weights land
dcomb=15652  dnow=0       coverage=100.0%
dcomb=15653  dnow=0       coverage=100.0%
```
`no_weights` FREEZES. Every miss is startup. §19 expected ~63% residual from §18's per-symbol
overwrite; that residual does not exist, because the same-slot fallback plus a sticky `valid` flag
means once ANY symbol of the period has weights, every symbol hits. **§18 item 2 (per-symbol
overwrite) is therefore NOT a coverage problem and can be dropped from the work queue.**

### A hypothesis was killed by measurement instead of by a debug session
Suspected next: the DU records `applied[]` per slot while the RU applies one vector per period, so
the two would disagree on slots 2,3,4. A counter added to measure it (`[CATB PERIOD] same=/diff=`)
**never fired even once** — proving `catb_bfw_attach` is only ever called with the period's first UL
slot, so the DU never wrote divergent per-slot vectors. Hypothesis wrong, cost ~1 run instead of a
session. The period fan-out added to `catb_bfw_attach` is harmless and correct; keep it.

### THE REAL BLOCKER: weight production deadlocks at high coverage
| counter | print rule | prints seen | implied rate |
|---|---|---|---|
| `[CATB] ref-symbol weight publish` | every 500 | **1** (at #1) | < 501 publishes/run |
| `[CATB WDIAG]` | every 500 | **1** | < 1000 partner-found |
| `[CATB DU] effective-channel` | every 20000 | **1** | < 20001 combined symbols |
| RU `[CATB KEY lookup]` asks | — | — | **120001** |
| RU sections with ef | — | — | **26001** |

The DU computes weights ~once per run, at startup. `catb_bfw_attach` caches the last good record,
so it re-serves that ONE pre-traffic vector forever — confirmed on the wire: the RU received
byte-identical `w[0..3]=(266,537)(-188,987)` at slots 6, 11 and 16, thousands of sections apart.
`sum_lcid4` frozen for the whole run => zero UL bytes. Throughput 0.0 Mbps, MCS 0,0.

**This is §17 bug 1 surviving one level up.** That fix made weight computation independent of
`g_mu_mimo_active` and `log2_maxh`, but NOT independent of co-scheduling: the partner scan
(`nr_ulsch_demodulation.c:1251-1266`) still requires two UEs on byte-identical PRBs in the same
slot, both with `mu_chest_frame/slot` stamped. So:

```
weights -> data decodes -> throughput -> scheduler co-schedules both UEs -> weights
```

At 5% coverage the loop limped (3.1 Mbps). At 100% coverage the DU is a 1-antenna receiver on
EVERY data symbol using one stale pre-traffic vector, decoding dies, the scheduler stops pairing
the UEs, the partner scan fails, and no new weights are ever produced. Higher coverage made it
strictly worse — 3.1 -> 0.0 Mbps. **The fix that closed the coverage bug is what exposed this.**

### Wire is proven healthy — the fault is above it, not in the fronthaul
`self_sum=828781 partner_sum=884850` (~1e6, the §17 bug-4 healthy magnitude), DU emits
`w[0]=(419,522)`, RU parses `extType=1 extLen=17 compMeth=0 iqWidth=0 n_ant=16`. Nothing zero,
nothing saturated. Do not re-investigate the fronthaul.

### NEXT — census FIRST, then fix
Do NOT jump to the fix. `[CATB WDIAG]` sits INSIDE `if (wpart >= 0)`, so its single print bounds the
partner-found path but says nothing about which earlier gate rejects. Add an exit-path census to the
weight-production block (the artifact that cracked §18 and §19): count `catb_comb` / not-a-DMRS-
symbol / `nb_rx_ant != nb_rx_ant_true` / ring null / already-published-this-slot / no partner /
buffer fail / sum-too-low / published. One run names the gate.

Expected answer is "no partner", and the standard fix is an SU fallback: with no partner, publish
matched-filter weights `w = h` for the single UE — the degenerate one-user case of the same MMSE
formula, not a hack. That bootstraps the loop (SU weights -> decodes -> throughput -> co-scheduling
-> MU weights). But CONFIRM WITH THE CENSUS FIRST.

### Still open, unchanged
- **Layer 0 only.** `oaioran.c` hardcodes layer 0, so UE1 is nulled by the combiner. Caps
  throughput regardless of the above.
- Cat-A control not re-run: no shared decode code was touched (`catb_weight_ring.h` untouched, all
  changes behind `OAI_CATB_BFW`), so only `liboran_fhlib_5g.so` rebuilt.

---

## 21. THE COMBINED PATH HAS NEVER DECODED (2026-07-31, later)

### Headline
Single UE, valid non-zero weights, `singular_prb=0/106`, **100% steady-state coverage** — and the
DU decodes NOTHING: `[FAILCLASS] dtx 1 ... llr 0 ... pwr 624 npwr 624`. Signal power EQUALS noise
power (0 dB). The DU is receiving noise on the combined stream.

**Therefore: §17's "first decode, 3.1 Mbps" was decoding the 95% of data symbols that were
forwarded UNCOMBINED, via the DU's ordinary per-antenna path — not the Cat-B combined path.**
Closing the coverage bug removed that residue and revealed that the combined path contributes zero.
Do not treat "3.1 Mbps" as evidence the combiner ever worked.

### Run ledger this session (106 PRB, CDL_A, 16 RX, TS=0.02)
| run | change | attach | coverage (steady) | Mbps | MCS |
|---|---|---|---|---|---|
| 1 | period-scoped `catb_bfw_get()` | 2/2 | **100%** | 0.0 | 2,0 |
| 2 | + DU period fan-out in `catb_bfw_attach` | 2/2 | 100% | 0.0 | 0,0 |
| 3 | + `[CATB PROD]` exit census | 2/2 | 100% | 0.0 | 0,0 |
| 4 | + SU fallback | **1/2** | 100% | 0.0 | 0 |
| 5 | (retry of 4) | **1/2** | 100% | 0.0 | 0 |
| 6 | + regulariser floor (weights now valid) | **1/2** | 100% | 0.0 | 0 |
| 7 | **N_UE=1** | 1/1 | 100% | **0.0** | 0 |

### CLOSED this session
1. **Coverage 5% -> 100%.** `catb_bfw_get()` resolves to the period's first UL slot via
   `catb_period_first_ul_slot()` (`oaioran_ru.c`, shared with `oaioran.c` through `oaioran_ru.h`),
   derived from `nTddPeriod` + `sSlotConfig[].nSymbolType[]`. Proof: `[CATB BFW] period scoping:
   nTddPeriod=5 first_ul_slot_in_pattern=1`; lookup `0/9128 -> 5754/9128`.
   **Read the `[CATB UL]` census as DELTAS between prints, not totals** — cumulative totals said
   63% while steady state was 100% (`no_weights` freezes after the first weights land).
2. **Weight-production deadlock.** Census named it: `nopartner=4317` vs `PUBLISHED=114` (97.4%
   failure); every other exit zero. The partner scan needs two UEs on byte-identical PRBs in the
   same slot, so production depended on the throughput it produces. SU fallback (zero the partner
   channel; the 2x2 MMSE reduces to `w[0]=conj(h0)`) took publishes 114 -> 1501+.
3. **All-zero weights on the wire.** With `h1=0` the Gram is Hermitian-diagonal so
   `det = (|h0|^2+nvar)*nvar` — PROPORTIONAL to nvar. Measured `nvar=0`, so the `dd<1e-9` guard
   zeroed all 106 PRBs. Floored the regulariser at 1. Confirmed: `singular_prb 106/106 -> 0/106`,
   wire vector `(0,0)(0,0) -> (0,82)(-2829,3209)`.

### OPEN
- **[BLOCKER] The combined stream carries no signal.** Run 7 isolates it: single UE, everything
  upstream healthy, `pwr == npwr` exactly. NEXT MEASUREMENT, and do not skip it: log the MAGNITUDE
  of the combined buffer at the RU immediately after `catb_combine_ul()`, and the magnitude of what
  the DU reads back on antenna 0. One of those is ~0 and it says which side is at fault.
  Suspect list, all UNVERIFIED: (a) combined buffer written to the wrong antenna/eAxC so the DU
  reads an empty buffer; (b) `>> 15` scaling — |w_a| ~ 2048 after L1 normalisation over 16
  antennas, so each term is x/16 and BFP at IQ_WIDTH=9 may quantise it to nothing; (c) h_eff
  computed against a different vector than the RU applied.
- **[BLOCKER for 2 UEs] One combined stream cannot serve two co-scheduled UEs.** SU weights beam at
  UE0 and null UE1 at 90 deg azimuth, so UE1's Msg3 dies (`MSG3 ULSCH with no signal`) and attach
  goes 2/2 -> 1/2, reproducible 3/3 (runs 4,5,6) and independent of weight quality (run 6 had valid
  weights). This is `oaioran.c:135` emitting layer 0 only. Per-layer BFW on distinct eAxC is
  REQUIRED for any 2-UE Cat-B number, not an optimisation.
- **SU fallback must not stay unconditionally on for multi-UE runs** in its current form: it
  beamforms the whole UL allocation, including the contention channel Msg3 arrives on.

### Method notes worth keeping
- A modulus-print counter's PRINT COUNT bounds the underlying rate for free: `[CATB] ref-symbol
  weight publish` prints every 500 and printed once => <501 publishes/run, against 26001 sections.
  No new run needed.
- The `[CATB PERIOD] same=/diff=` counter NEVER FIRING refuted a hypothesis (DU/RU per-slot vector
  mismatch) in one run instead of a session. Instrument hypotheses so they can be falsified.
- Cat-A control still owed: `nr_ulsch_demodulation.c` is shared decode code and the regulariser
  floor touches the MU arithmetic (by ~1e-5, but show it, do not assume it).

---

## 22. ROOT CAUSE OF "NEVER DECODED": the DU's receive ring was NEVER MAPPED (2026-07-31)

### The find
`catb_read_applied_weights()` mapped its OWN private handle behind `if ((tries++ % 2000) != 0)
return 0;`. First attempt at call 0 — before the export path has created the ring. Next attempt at
call **2000**. But that function is reached only a few hundred times per run when nothing decodes.

**A third deadlock: the ring maps only after 2000 combined-receive calls, but there are only a few
hundred such calls because nothing decodes, because the ring isn't mapped.**

So for every run in this project's history the DU sat on its antenna-0 fallback
(`wr=32767, wi=0`) while the RU combined with real 16-antenna weights. The two sides were never
running the same algorithm. Proof, from run 9 (single UE):
```
[CATB MAG-B] n_w=0 |rx_combined|=108336 |h_eff|=167454 |H_ant0|=168730 heff/H=0.992
```
`heff/H = 0.99` is the FALLBACK IDENTITY (h_eff == H_ant0). And `weight ring mapped for receive`
is absent from the log entirely. In 2-UE runs it did cross 2000 ("after 2005 attempts"), which is
why this hid for so long.

### Fix — deletion, not addition
`catb_get_ring()` already holds a mapped handle IN THE SAME PROCESS. The second private mapping was
never needed. Removed it and its retry schedule; added `[CATB DU] applied_read hit/call` so the path
can never be silently dead again.

**Result: hit/call 0 -> 1811/2001 (90.5%), and Probe B now reports `n_w=16` on every sample.**

### The probes that found it (keep both)
- `[CATB MAG-A]` in `nr-oru.c` after `catb_combine_ul()`: `|combined|` vs `|ant0|`.
- `[CATB MAG-B]` in `nr_ulsch_demodulation.c` in the `catb_comb` branch: `|rx_combined|`, `|h_eff|`,
  `|H_ant0|` (the control accumulated from `tmp` INSIDE the extraction loop — reading
  `ul_ch_estimates` directly is the raw frequency-domain buffer and gives zeros).
- **Gate probes on signal being present** (`m0 > 0`), or they mostly sample IDLE UL slots and read 0.
- **Cadence matters**: at `% 20000` Probe B fired ONCE per run, on an `n_w=0` fallback symbol. Use
  `% 200`. A probe that samples the wrong path is worse than no probe.

### STILL 0 Mbps — two new measured leads, both open
1. **The two ratios do not track each other.** `|combined|/|ant0| ~= 0.14` (RU) vs
   `|h_eff|/|H_ant0| ~= 0.019-0.098` (DU), one sample 0.778. `y = w^H x` and `h_eff = w^H H` are the
   SAME projection, so if both sides applied the same w these must agree. A ~7x discrepancy means
   they do not. NEXT: log the applied vector on both sides FOR THE SAME (slot, symbol) and diff it
   element-by-element — not magnitudes, the actual 16 values.
2. **Double normalisation crushes weights to zero.** `catb_publish_weights` scales to
   `29000/sqrt(wmax)`, then `catb_bfw_attach` L1-rescales by `32767/272350 ~= 0.12`. Typical Q15
   components land ~1000 and the weakest antennas quantise to `(0,0)` — observed `w[0]=(0,0)` on
   both sides. Then `catb_combine_ul` and the h_eff loop truncate `>>15` PER TERM inside the
   accumulation, losing precision 16 times instead of once. Suspect, not proven.
3. **hit/call is 90.5%, not 100%.** The ~9.5% miss makes those symbols use the fallback while the RU
   combines them — the partial-coverage failure mode from §17 (a TB spanning both dies). Check
   whether the misses are a startup transient (as the coverage census turned out to be) by
   differencing successive `hit/call` prints.

### Run ledger, this session
| run | change | attach | coverage | applied_read | Mbps |
|---|---|---|---|---|---|
| 1-3 | period-scoped lookup + census | 2/2 | 100% | 0 (broken, unknown) | 0.0 |
| 4-6 | SU fallback, regulariser floor | 1/2 | 100% | 0 (broken, unknown) | 0.0 |
| 7-9 | N_UE=1 isolation + magnitude probes | 1/1 | 100% | **0 (PROVEN broken)** | 0.0 |
| 10 | shared ring handle | 1/1 | 100% | **1811/2001** | 0.0 |

---

## 23. TWO PUBLISHERS, ONE RING — the zero-weight source (2026-07-31, later)

### Headline
`catb_publish_weights` has TWO call sites writing the SAME ring. Measured side by side in one run:
```
src=1 (ref-symbol): WRITER nonzero=3392/3392 first=0 last=3391            <- healthy
src=2 (MU-IRC):     WRITER nonzero=1696/3392 first=0 last=1695 q=(0,0)    <- half zeros
reader (attach):    nonzero=1590/3392        last_nz=1695 iq=(0,0) l1=0   <- got src=2's
```
src=2 was clobbering src=1's good records. **This is why the wire carried w=(0,0) and the combined
path produced nothing.**

**Cause:** `chF2` is packed at 6 REs/PRB on a DMRS symbol (extent 636) while `buffer_length` says
1272 (12/PRB). So `re = prb*12 + 6` runs past the populated region from prb 53 up
(53*12+6 = 642 > 636) and reads uninitialised ZEROS — no break, no truncation, silent garbage.

**Fix:** src=2 OFF by default (`OAI_CATB_PUB_IRC=1` to re-enable). §17 already made the ref-symbol
path the first-class producer; the passive Step-2 exporter is vestigial. One producer, one ring.

**Result:** reader now sees `nonzero=3392/3392 last_nz=3391 iq[0..3]=(-52,77)(-1889,589) l1=32768`,
and the RU combines for real: `[CATB MAG-A] |combined|=32303 |ant0|=23489 ratio=1.375`.

### Also fixed this round
- **SU fallback OFF by default** (`OAI_CATB_SU_BFW`). It was never needed: with no weights the RU
  forwards all 16 antennas and the DU decodes per-antenna, which is how the loop bootstraps.
  It was also harmful — one wideband beam serves one UE, so it nulled the co-scheduled UE and
  killed its Msg3. **attach 1/2 -> 2/2** the moment it was disabled. NOTE: `nopartner` is still
  ~97% (4321 vs PUB_MU=118) even with §22 fixed, so the partner scan genuinely does fail most of
  the time — the deadlock was NOT purely a symptom of §22. But ~118 publishes/20000 calls is
  plenty; it never needed the SU crutch.
- **ONE normalisation, not two.** `catb_publish_weights` now normalises per (PRB, layer) straight
  to the L1 budget `sum(|wr|+|wi|) = 32767` — the only constraint that matters, since the RU's
  `y = sum_a x_a*conj(w_a) >> 15` saturates above it. The old max-component `29000/sqrt(wmax)`
  followed by an L1 rescale of ~0.12 in `catb_bfw_attach` quantised to Q15 TWICE. The attach-side
  rescale now never fires (`BFW normalised` logged 0 times).
- **applied_read hit/call = 100% steady state.** The 90.5% in §22 was a startup transient — same
  trap as the coverage census. Difference successive prints; never read a cumulative total.

### DEAD ENDS (do not re-run these)
- "L1 normalisation starves weak antennas below the Q15 floor" — REFUTED by `[CATB QUANT]`:
  `scale=2.669e6`, `w_raw=(2.779e-04,-2.215e-04) -> q=(742,-591)`. Quantisation is fine.
- "8-antenna layout" — `last_nz=1695` equals `(105*2+1)*8+7` exactly, but BOTH sites log
  `n_ant=16`. Coincidence. Print the field, do not solve the arithmetic backwards.
- "RE stride at src=2, derive it from buffer_length" — `buffer_length/rb_size = 1272/106 = 12`,
  which is what it already was. `buffer_length` is ITSELF the over-stated quantity.
- "Stale mmap / incoherent ring" — `widx=1` (PHY, at publish #2) vs `widx=150` (attach, later) is
  consistent, not a discrepancy. The ring is shared and advancing. §22's failure mode is not back.

### STILL 0 Mbps — the remaining gap is SCALING, not correctness
Everything upstream is now measured healthy: attach 2/2, coverage 100%, applied_read 100%,
full non-zero records, RU combine ratio 1.375, `n_w=16` on both sides with matching `w[0..3]`.
What is left:
```
[CATB MAG-B] |rx_combined|=5917  |h_eff|=61328  |H_ant0|=179805  heff/H=0.341
[FAILCLASS]  dtx 1 ... pwr 663 npwr 663 llr 0        (0 dB: signal == noise)
```
1. **`|rx_combined|` is ~5900 in EVERY sample** (5917/6021/5957/5934/5949) while `|H_ant0|` varies
   (167k-180k). A received magnitude independent of the channel is the signature of NOISE, not
   signal. The RU sent `|combined|=32303`; the DU sees ~5900 over a comparable RE count.
2. **`heff/H = 0.22-0.36`**, where a coherent MRC sum with L1-normalised w should land near 1.
   Suspect per-term `>>15` truncation: with `|x_a| ~ 18/RE` and `|w_a| ~ 2048`, each term is
   `18*2048 >> 15 = 1.125 -> 1`. Sixteen terms of ~1 instead of ~25. **Accumulate in int32 and
   shift ONCE at the end**, on both the RU combine and the DU h_eff loop. UNVERIFIED.
3. Dynamic range: the combined stream is ~25/RE (5 bits) before BFP at IQ_WIDTH=9.

NEXT MEASUREMENT: log `|rx_combined|` on a REFERENCE symbol (uncombined, known-good) in the same
units as a data symbol. If reference is ~30x larger, the combined stream is being crushed in the
RU->DU path and item 3 is the cause; if they match, the fault is in h_eff (item 2).

### Run ledger
| run | change | attach | coverage | applied_read | record | Mbps |
|---|---|---|---|---|---|---|
| 1-3 | period-scoped lookup, census | 2/2 | 100% | broken (unknown) | zeros | 0.0 |
| 4-6 | SU fallback, regulariser floor | 1/2 | 100% | broken | zeros | 0.0 |
| 7-9 | N_UE=1, magnitude probes | 1/1 | 100% | **proven broken** | zeros | 0.0 |
| 10 | shared ring handle (§22) | 1/1 | 100% | 1811/2001 | zeros | 0.0 |
| 11-19 | MU-only, 1 norm, layout probes | 2/2 | 100% | 100% | **half zeros (src=2)** | 0.0 |
| 20 | src=2 OFF | 2/2 | 100% | 100% | **3392/3392 full** | 0.0 |

---

## 24. FIRST DATA THROUGH THE COMBINED PATH — wideband BFW is the blocker (2026-07-31)

### Headline
**`sum_lcid4` CLIMBS for the first time: 15839 -> 20931 -> 34898 -> 40397 -> 47963.**
0.086 Mbps (sim), MCS 0,0. Tiny, but the Cat-B COMBINED path has never passed a byte before —
§17's 3.1 Mbps was the uncombined residue (see §21). This is the first real one.

### Two fixes got there
1. **Fixed-point: accumulate full precision, shift ONCE.** Both combiners had `>>15` INSIDE the
   16-term antenna loop (`nr-oru.c` catb_combine_ul, `nr_ulsch_demodulation.c` h_eff loop).
   On the RU side the operands are small — `|x| ~ 18/RE`, `|w_a| ~ 2048` — so each term was
   `18*2048 >> 15 = 1.125 -> 1` and weaker antennas truncated to ZERO. Safe to accumulate
   unshifted because w is L1-normalised (`sum_a |w_a| <= 32768`), bounding the sum at
   `32767*32768 = 1.07e9 < INT32_MAX`. **The single-normalisation change (§23) is what makes the
   int32 accumulator legal** — int64 would need 64 kB of VLA on a decode thread that has already
   overflowed its stack twice.
2. **src=2 disabled** (§23) so the ring holds one producer's records.

### THE COUNTERINTUITIVE RESULT THAT LOCATED THE BLOCKER
Removing the truncation made the combined output SMALLER: RU ratio **1.375 -> 0.209**,
`|rx_combined|` 5917 -> 1286. Truncation can only LOSE magnitude in a coherent sum, so the larger
old number was rounding residue, not signal. The true coherent sum is small => **the 16 terms
CANCEL**, i.e. w is not aligned with the H it is applied to. Two independent measurements agreed:
RU `|combined|/|ant0| = 0.209` and DU `heff/H = 0.15-0.31`, both of which should be ~1.

### CONFIRMED: the wideband single-vector approximation is the cause
`catb_bfw_attach` takes ONE vector from the mid-band PRB and applies it across all 106 PRBs. That
requires a flat channel:
```
coherence BW ~ 1/(2*pi*DS) = 1/(2*pi*0.1us) ~ 1.6 MHz
occupied BW  = 106 PRB * 30 kHz            = 38 MHz     <- ~24x wider
```
Control run with `CHANMOD=0` (flat channel), everything else identical:
| metric | CDL_A DS=0.1us | flat | expected |
|---|---|---|---|
| RU `\|combined\|/\|ant0\|` | 0.209 | **0.735-0.874** | ~1 |
| DU `heff/H` | 0.15-0.31 | **0.759-0.887** | ~1 |
| throughput | 0.0 | **0.086 Mbps, climbing** | - |

**§17's "adjacent-PRB weight correlation 0.91-0.96, so wideband costs a real but bounded amount"
is WRONG as applied.** That measured ADJACENT PRBs; the wideband vector is applied +/-53 PRBs from
where it was computed. Across the band the correlation collapses. **Per-PRB / bundled BFW (ext-11,
Step 3b) is REQUIRED for any channel-model run, not a refinement.**

### Why MCS is still 0,0 even in the flat control
The published vector is dominated by ONE antenna: `w[0..3]=(28380,4352)(0,0)(0,0)(0,0)`, and
`(14529,10498)(512,2)(512,2)(512,2)`. With `CHANMOD=0` every antenna sees an identical signal, so
H is effectively rank-1 and the MMSE solution is degenerate — no array gain is available to find.
The flat control validates the MECHANISM; it is not a throughput test.

### NEXT
Run a channel that is frequency-FLAT but spatially RICH: CDL_A with `CHAN_DS_US=0.005`
(coherence BW ~32 MHz, comparable to the 38 MHz band) or a small-DS TDL. That isolates array gain
from frequency selectivity. Expect ratio ~1 AND real array gain AND MCS above 0. If that works,
the remaining agenda is per-PRB BFW (3b) and per-layer BFW for the 2-UE case.

### Run ledger addendum
| run | change | ratio | heff/H | Mbps |
|---|---|---|---|---|
| 20 | src=2 OFF | 1.375 (residue) | 0.34 | 0.0 |
| 21 | accumulate-then-shift | 0.209 (true) | 0.15-0.31 | 0.0 |
| 22 | + CHANMOD=0 flat control | **0.735-0.874** | **0.759-0.887** | **0.086, climbing** |

### §24 CORRECTION (2026-08-01): the flat-channel result was N=1 and did NOT reproduce
| run | XRAN_MAX_SET_BFWS | sum_lcid4 | RU ratio |
|---|---|---|---|
| 22 | 1 | climbed 15839 -> 47963 | 0.735-0.874 |
| 23 | 64 | 4418, UEs dropped | 0.532 |
| 24 | 64 | froze at 5791 | 0.212 |
| 25 | **1 (reverted)** | froze at 4693 | 0.175 |

Run 25 reverts the ABI change and STILL stalls => **the XRAN_MAX_SET_BFWS 1->64 enlargement is
EXONERATED** (rebuild recipe below, it is safe to re-apply). But it also means **run 22 was the
outlier, not runs 23-25.** `CHANMOD=0` makes every antenna see an identical signal, so H is
effectively rank-1, the MMSE solution is degenerate and UNSTABLE: ratio spans 0.175-0.874 across
four runs of an IDENTICAL config. **CHANMOD=0 is not a usable control.** §24's "first data through
the combined path, 0.086 Mbps climbing" stands as an observation but NOT as a reproducible result.

The wideband diagnosis itself is unaffected — it rests on CDL_A ratio 0.209 vs the coherence-BW
arithmetic, not on the flat-channel number. But the CONTROL must be re-done with a channel that is
frequency-flat AND spatially rich: CDL_A with a small delay spread (`CHAN_DS_US=0.005` =>
coherence BW ~32 MHz against the 38 MHz band), NOT CHANMOD=0.

**libxran rebuild recipe** (needed for 3b; both §7 traps hit):
```bash
cd oaicicd/test_dir/phy-f-1.0/fhi_lib/lib
export RTE_SDK=.../dpdk-stable-20.11.9
export XRAN_DIR=.../phy-f-1.0/fhi_lib      # NOT phy-f-1.0 — Makefile wants $XRAN_DIR/lib/src
export WIRELESS_SDK_TOOLCHAIN=gcc XRAN_LIB_SO=1   # without XRAN_LIB_SO it builds only .a
make -j$(nproc)
# then rebuild oran_fhlib_5g — libxran and liboran_fhlib_5g share the struct layout
```
Backup of the pre-change .so: `build/libxran.so.bak_prebundle`.

---

## 25. WHAT RUNS 25-34 ACTUALLY ESTABLISHED (2026-08-01) — read the retractions first

### RETRACTIONS — three of my own conclusions were wrong. Do not act on them.
1. **"Wideband BFW is the blocker" (§24) — REFUTED.** Control: CDL_A `CHAN_DS_US=0.005`
   (coherence BW ~32 MHz vs the 38 MHz band, i.e. 20x flatter) gives ratio **0.211** against
   **0.209** at DS=0.1us. Frequency selectivity changes NOTHING. Per-PRB BFW (3b) is NOT the fix,
   and `XRAN_MAX_SET_BFWS` was the wrong tree. It is reverted to 1.
2. **"Coherence = 0.25 = 1/sqrt(16) proves incoherent combining" — INVALID MEASUREMENT.** The probe
   sampled ONE RE at `fp->ofdm_symbol_size/2`. In OAI's rxdataF, DC is index 0 and the spectrum
   WRAPS, so the middle index is the GUARD BAND. It was comparing weights against noise, which
   returns ~1/sqrt(16) BY CONSTRUCTION — which is exactly why the number never moved.
   **Corrected probe (low positive-frequency bins, averaged over ~18 REs): coherence 0.66-0.89.**
   The combining was largely coherent all along.
3. **"CHANMOD=0 is a usable flat-channel control" — NO.** All antennas see an identical signal, H
   is rank-1, the MMSE solution is degenerate and unstable: ratio spanned 0.175-0.874 over four
   runs of an IDENTICAL config. §24's "first data through the combined path, 0.086 Mbps" was N=1
   and did not reproduce.

### THE RIG WAS BROKEN FOR RUNS 28-31 — and the documented preflight did not catch it
Cat-A control (all Cat-B knobs off) failed at **attach 0/2**. After `docker restart oai-smf
oai-upf oai-amf` + 35 s, Cat-A gave **175.2 Mbps, MCS 28,28, attach 2/2** — clean convergence
0 -> 10,5 -> 23,17 -> 28,28. So:
- **Cat-A is UNREGRESSED** by every change this session to shared decode code. Control satisfied.
- Runs 28-31 are VOID (stale CN contexts after ~30 runs of abrupt UE kills).
- **`grep -c "no SMF candidate"` returned 0 THROUGHOUT the failure.** The §8 CN preflight cannot
  see this mode. **NEW RULE: run the Cat-A control the moment runs start behaving oddly — it is
  the rig check, not just a regression guard.** I ran it three runs too late.
- **§8's "dead + ~20 dB PRACH = fronthaul" does not discriminate here.** Measured 19.9/20.0/20.3/
  20.3 dB across runs 26-29 — identical for the two that attached and the two that did not.

### KEPT (algebraically justified, still UNVERIFIED by measurement)
`catb_publish_weights` emits `W = G^-1 H^H`, so `w[l][a] = sum_i invG[l][i]*conj(h_i[a])` — the
conjugate is ALREADY in w, and the MMSE estimate is `s_l = sum_a W[l][a] * x_a`, a PLAIN product.
Both combiners were applying `x*conj(w)`, conjugating twice. Fixed in `nr-oru.c
catb_combine_ul` and the `nr_ulsch_demodulation.c` h_eff loop. Throughput did not move, so this is
correct-by-derivation but not demonstrated.

### ALSO KEPT (correct, low risk)
- **Accumulate full precision, shift ONCE** in both combiners. The `>>15` was INSIDE the 16-term
  loop; on the RU side `|x| ~ 18/RE` against `|w_a| ~ 2048` truncated every term to 1 and weaker
  antennas to 0. Legal in int32 only because w is L1-normalised (`sum|w| <= 32768` bounds the sum
  at 1.07e9). Removing the truncation made |combined| SMALLER, which proved the old larger figure
  was rounding residue.
- **ONE normalisation** (per PRB+layer, straight to the L1 budget) instead of max-component then
  L1-rescale. `BFW normalised` now never fires.
- **src=2 (MU-IRC passive export) OFF** by default — it published half-zero records over src=1's
  good ones. `OAI_CATB_PUB_IRC=1` to re-enable.
- **SU fallback OFF** by default (`OAI_CATB_SU_BFW=1` to enable) — it beamformed during attach and
  nulled the co-scheduled UE's Msg3 (attach 2/2 -> 1/2, reproducible 3/3).

### STATE: still 0 Mbps on Cat-B, and the NEW lead
Run 34 (valid rig, corrected probe): attach 2/2, coherence 0.66-0.89, ratio 0.764 — but
`w[0..3]=(22380,-768)(0,0)(0,0)(0,0)`. **The weight vector is DEGENERATE — all energy on antenna 0,
the other 15 quantised to zero.** A single-antenna vector is trivially "coherent" (one term) and
delivers NO array gain: ratio 0.764 ~= 22380/32768. Earlier runs showed spread vectors
`(1565,5)(1293,-1535)(1288,-973)(512,1503)`, so this varies run to run.
**NEXT: find why the MMSE solution collapses onto one antenna.** Log the per-antenna |h| spread and
the Gram condition number at publish time. Suspects, all unverified: ill-conditioned G, a channel
estimate populated on only one antenna, or the L1 normalisation crushing 15 antennas after one
dominates. Measure before fixing — three hypotheses died this session, all from reasoning ahead of
a probe, and TWO of the probes themselves were buggy (blind sampling; wrong control array; guard
band). **When a probe returns a suspiciously round number (0.25 = 1/sqrt(16)), check the sampling
point BEFORE believing it.**
