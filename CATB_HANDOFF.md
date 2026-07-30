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
