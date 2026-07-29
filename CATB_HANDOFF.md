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
| **3a.2 RU registers BFW rx** | **IMPLEMENTED, UNVERIFIED** — `xran_5g_bfw_config` returns OK (1 log line) but **callback never fired (0 lines)**; run did not complete. **VERIFY FIRST.** |
| 3a.3 RU applies weights | **NOT STARTED** — design below |
| 3b per-PRB, 3c SIMD | not started |
| **4 latency sweep** | **NO VALID DATA** — mechanism bug found, see §4 |

**Baseline for every gate:** 106 PRB w9, 2 UE, sigma=7 => **177.8 Mbps, MCS 28/28, PRACH ~56 dB**.
273 PRB baseline: **398.2 Mbps, MCS 28/28**.

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
