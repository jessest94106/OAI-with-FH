# FH-Load-vs-UL & vrtsim Wide-BW Chanmod — Findings, Open/Closed, Target
_Last updated: 2026-06-09 (rev 5). vrtsim/real-FH thread (NOT the rfsim thread — see `RFSIM_UL_THROUGHPUT_HANDOFF.md` for that one)._

---

## ✅✅ 2026-06-09 13:07 (rev 5) — **WEDGE SOLVED, GATE GREEN.** UE attached (first since 06-07 16:22)

`PRB=24 FHload=145.2 attached=YES ul_sim=6.11 cal=5.97 R=0.256 — stack-try 1, UE-try 1, UL-ping 5/5.`
The rev-3 "directional DL wedge" was **TWO stacked faults**, both found, fixed, and verified end-to-end:

### Fault A — VF0 admin MAC clobbered → X710 VEB black-holes DL
VF0 (RU U-plane) admin MAC was a **random value** (`d6:8b:e9:1c:f9:d5`) instead of `00:11:22:33:64:66`.
VEB forwards unicast by MAC ⇒ all DU DL U-plane (dst 64:66) silently dropped. UL survived (RU spoofs
src 64:66, spoofchk off); C-plane survived (VF1 MAC intact) — the exact directional signature.
**Proof:** i40e per-VF HW counters (`ip -s link show eno1np0`): VF2 TX 10,020 frames/5s, VF0 RX **0**;
after `sudo ip link set eno1np0 vf 0 mac 00:11:22:33:64:66` → VF0 RX instantly 0→4 MB.
Survives reboots because it re-arises per `prepare_network.sh` cycle (kernel creation-MAC surviving a
silently-failed set, or one-time runtime clobber at first RU init — exact trigger unresolved; the
**fix is idempotent**: verify+assert MACs BEFORE each RU launch, now in `fh_sweep_vrtsim.sh`).
⚠️ Never `ip link set vf mac` while the RU runs — VF reset → TX stall → mbuf-pool drain → the #6
`xran_oru_send_pusch` mbuf assert (reproduced live; #6's mechanism confirmed).

### Fault B — vrtsim ring timescale missing → 100% of DL IQ writes TOO_LATE
The RU's vrtsim server ring clock advances `sample_rate × timescale × wall` with **`--vrtsim.timescale`
default 1.0** (vrtsim.c:87,358). `run_ru.sh` forwards it only via `${VRTSIM_RU_EXTRA_ARGS}` — which
`fh_sweep_vrtsim.sh` never set. Ring at 1.0× vs xran-stamped writes at 0.25× ⇒ ring races ahead ⇒
**every DL write CHANNEL_ERROR_TOO_LATE ⇒ silently dropped ⇒ shm ring empty (28 nonzero bytes/68.8 MB)
⇒ UE scans pure zeros.** **Proof:** graceful-SIGINT vrtsim_end stats: `Realtime issues: TX 100.00%`,
`Average TX budget -113,890,642 µs` (≈-114 s = rate divergence, not jitter).
**This was rev-3's missing piece:** the "lost change" was the LAUNCH ENV (`VRTSIM_RU_EXTRA_ARGS`),
not source — why all on-disk artifacts were "identical to the working state" yet nothing attached, and
why the epoch fix was "necessary, not sufficient" (epoch = 2nd of THREE clock anchors:
XRAN_TIME_EPOCH, XRAN_TIMESCALE, **vrtsim ring timescale**).
**Fixes applied:** `fh_sweep_vrtsim.sh` RU launch now passes `VRTSIM_RU_EXTRA_ARGS="--vrtsim.timescale $TS"`;
`sweep_iq_width.sh` chanmod-OFF branch now forwards timescale too (was `""` → would have false-failed
the H1 106×4-OFF control) + emits the multi-antenna ue_config/client-num-rx-antennas for OFF cells.

### New traps learned (add to pre-run lore)
- `scaling_cur_freq`/`/proc/cpuinfo MHz` are **stale on nohz_full isolated cores** (showed 1746 MHz while
  perf-counter真 freq was 4.42 GHz). Measure real freq with `sudo perf stat -C <core> -e cycles -- sleep 1`.
- The RU init line `VRTSIM: UE 0 … Model 0 (TDL-A) …` prints **unconditionally** (parse_ue_config) — it
  does NOT mean chanmod is on (chanmod defaults 0).
- `hw_log_level="warn"` suppresses ALL vrtsim LOG_I(HW) **including the shutdown stats** — for FH/ring
  diagnostics set hw="info" for the run and SIGINT (not pkill -9) to harvest
  `Realtime issues / too early / Average TX budget / TX budget histogram`.
- DU software `fh_load_stats.csv` reports **sim-rate** (wall×1/ts); i40e per-VF HW counters report wall —
  factor 4 mismatch at ts=0.25 is expected, not loss.
- Launch only on a settled box (1-min load <2): launching right after bring-up/a prior stack reproduces
  the "TTI processing delay skipping → race storm → no NGSetup" failure even with all fixes in.
- i40e per-VF HW counters (`ip -s link show <PF>`) count even with the VF on uio/DPDK — best
  non-perturbing FH direction/delivery probe. The VF4 capture port sees no unicast (VEB doesn't flood).

**Status now:** G0 24×1 ✅ → running L1/L2 (51,106×1), then the MIMO/chanmod matrix per
`WIDEBW_4X4_SWEEP_PLAN.md`. The old "NIC needs cold power-cycle" hypothesis is DEAD — no cold cycle needed.

### rev-5 addendum (13:37) — wide-BW fix ladder, 51×1 ✅ DATUM COLLECTED
`51×1 OFF: status=ok, FH=310.4 Mbps measured, UL=3.535 wall → **14.1 Mbps sim** (≈ historical 15.16 ✓), loss 0.00%, ul_sym 99.97%.`
Three more wide-BW-only faults found+fixed on the way (24 PRB never hit any of them):
1. **`fh_sweep_vrtsim.sh` wide-BW table is off the SSB sync raster** (51→4054.44 MHz, 106→4064.52; both
   +360 kHz off the 1.44-MHz raster) → DU dies in `check_ssb_raster` pre-NGAP. Its 51/106 rows were NEVER
   validated (script written mid-wedge). → wide-BW cells run via `sweep_iq_width.sh` (SSB fixed at on-raster
   4049.76 MHz, pointA moves; verified DU `N_RB 51` + RU `nDLRBs 51`). 24 PRB via fh_sweep_vrtsim is fine.
2. **Timeout mis-calibration under dilation:** UE_WAIT 120 wall-s = only 30 sim-s at ts=0.25; sync needs many
   scan cycles (even the GOOD 24×1 grinds through ~179 `synch Failed` first). → RU_WAIT 40 / DU_WAIT 180 /
   **UE_WAIT 360**. ("51 never syncs" was FALSE — PBCH+SIB1 decode fine at 51.)
3. **DU/RU PRACH-frequency mismatch (the historical wide-BW PRACH bug, now pinned to a line):**
   `sweep_iq_width.sh:158` centers the DU's `prach_msg1_FrequencyStart = BW/2-6` (19 @51, 47 @106) but never
   patched the RU's `prach_msg1_start` (stayed 0) → RU extracts PRACH at PRB 0 while the UE transmits at 19 →
   gNB `prach energy 0.0 dB`, `RAR reception failed` ×20. **Fix:** the same perl block now patches RU_CONF's
   `prach_msg1_start` in lockstep. (PRACH **timing** fix T1a_cp_ul=535 was already in the conf backups.)
- **N_RB note:** 52 is NOT a valid µ1 width (`get_samplerate_and_bw` asserts) — use 24/51/106; the plan's
  "use 52" guidance is dead, and the odd-PRB worry is refuted (51 attaches).
- **#9-relevant measurement:** 51×1 OFF write margin = `Average TX budget +133 µs` (TX 0% late) — POSITIVE but
  THIN. The fixed 4096-sample TX advance halves in wall-time per 2× sample rate; chanmod actors + 4 antennas
  eat exactly this margin → unified hypothesis for the historical "chanmod×BW cliff" (= wedge-B's TOO_LATE
  drop reached by compute instead of clock-rate). The matrix's per-cell budget harvest will quantify it.
- **Ring-snapshot caveat:** an "empty" /dev/shm ring does NOT mean no writes — the UE's destructive read
  (memset-after-read) keeps it near-zero in steady state. Use the vrtsim_end TX stats, not ring snapshots.
- New tooling: **`run_matrix.sh`** (cell × N-trial runner embedding every invariant: settle-gate, hugepage
  find-delete, MAC assert pre-launch, 3 clock anchors, conf restore + min_grant re-apply, summary.csv harvest).

### rev-5 addendum 2 (14:00) — TOO_LATE wall MECHANISM CONFIRMED; 106 has one residual RU PRACH bug
**`--vrtsim.tx-sample-advance` (default 4096 SAMPLES) is the #9-class wall.** Fixed sample count ⇒ the
writer's sim-time lead shrinks with sample rate: 266 µs @24 PRB, 133 µs @51, 66 µs @106. **Proof:** at 106
the UE's PRACH arrived in the RU's time domain as `slot_nz=2/4/6` (2 samples/symbol — everything else
TOO_LATE-dropped); with `--vrtsim.tx-sample-advance 16384` → `slot_nz=2224/4416` (dense, healthy).
Now wired through `sweep_iq_width.sh` (both branches) + `run_matrix.sh` via `VRTSIM_TX_ADVANCE` (default 16384).
Raising it is timing-safe (it's a write DEADLINE lead, not added air latency).
**Unified #9 hypothesis (quantified):** 51×1-OFF measured budget +133 µs ⇒ chanmod actor latency ×
antennas × BW all eat the same margin ⇒ the historical "chanmod×BW cliff" = this wall reached by compute.
**106 residual bug (OPEN):** with dense slot energy + correct RU prach cfg (`nPrachFreqStart 47`,
verified in the RU's parsed-config dump), the RU's PRACH **payload on the wire is all-zeros**
(`non_zero_compressed=0/336` on every section) while its own extraction FFT has energy
(`fft_energy=81736`). ⇒ the bug is between `prachF` and the payload write in `xran_oru_send_prach()`
(`oaioran_ru.c` ~1095-1170) — specific to the 106-PRB/2048-dft geometry (51/1024-dft works). 4 candidate
spots: prachF buffer fill length, kbar slice, int16 scaling at 2048-FFT (extra >>1?), BFP-9 of small values.
**Log-reading traps found:** (a) the DU's `[gNB PRACH RX]` print is UNLIMITED for nonzero payloads but
first-10-only for all-zero payloads — "only 10 prints" means "all zeros", NOT "only 10 sections sent";
(b) sweep_iq_width DOES restore confs at end — post-run conf contents are NOT what the trial ran with;
verify via the RU log's parsed-config dump instead; (c) idle PRACH slots show `non_zero_compressed=2/336`
(noise floor) — "2 nonzero" ≠ preamble.
**Datums:** G0 24×1: FH 145.2, UL 6.11 sim. L1 51×1: FH 310.4, UL 14.1 sim, 0% loss. 106×1: FH 635.8
measured (DL side fine; attach blocked by the PRACH payload bug above).
**Matrix pass-1 RESULT (14:55, CSV `logs/fhsweep/matrix_20260609_135912.csv`) — #9 RESOLVED IN SUBSTANCE:**

| Cell (chanmod-ON) | FH Mbps | k/N | UL sim | failure mode |
|---|---|---|---|---|
| 24×2 | 302 | 0/2 | — | Msg3/RAR fail (PRACH detected 41 dB) |
| 51×2 | 621 | 1/2 | **14.0** | t1: `xran_queue_length==0` DU assert (cold-start race) |
| 24×4 | 603 | 0/2 | — | Msg3/RAR fail (PRACH 20 dB) |
| **51×4** | **1242** | **2/2 ✅** | 0.64/0.56 | — (UL SNR 0 dB → MCS 0 caps UL) |

**Reading:** the historical "hard cliff" is DEAD as a concept — the worst cell (51×4) attaches 2/2 while
the easiest (24×2) went 0/2. Attach is NOT ordered by load, BW, or antennas. The old cliff = five
infrastructure bugs (all fixed today) + cold-start racing + per-cell SNR regimes, observed through
1–2-attempt samples. **Iso-load control:** at ~610 Mbps, 51×2 crashed once while 24×4 never crashed ⇒
the xran_queue crash is a flaky 51-PRB-geometry race, NOT a load wall (51×2 t2 + both 51×4 trials ran
crash-free at up to 2× that load).

**Surviving REAL defects (the new #9 successors):**
1. **UL chanmod multi-antenna scaling (OPEN, the big one):** at 51×4 the gNB measures UL **SNR 0.0 dB**
   (expected ~30 dB at AWGN/no-ploss) → MCS 0/QPSK/DTX 16% → UL 0.6 Mbps. Same class as PRACH detect
   energy halving per antenna doubling (41 dB @2ant → 20 @4ant). DL is EXONERATED (51×4 DL: MCS 27,
   BLER 0.056). Suspect: per-TX-stream combine in the UL chanmod path loses/divides power
   (`vrtsim.c` UL combine ~1137-1186; note single-UE read duplicates stream 0 → all RX antennas
   identical → single-UE UL is inherently RANK-1 through vrtsim). The 24-cell "RAR failures" are
   probably the SAME defect (weak Msg3, not missed RAR — DL is fine).
   **Measurement workaround:** `--vrtsim.rx-target-snr-db` AGC (commit a559a1f755) pins UL RX SNR →
   MCS recovers → FH-load-vs-UL grid measurable NOW without fixing the combine.
2. **106-PRB RU PRACH payload all-zeros** (OPEN, see addendum 2) — blocks the 106 column's attach.
3. xran_queue cold-start race at 51-PRB geometry (flaky, retry-able; root-cause optional).

**PASS-2 PLAN:** (a) chanmod cells + `--vrtsim.rx-target-snr-db 30` (UE side) → real UL numbers across
the grid; (b) N=5 on the 51 column; (c) `51:2:0`/`51:4:0` chanmod-OFF controls (crash incidence);
(d) fix the 106 PRACH payload path (`oaioran_ru.c` ~1095-1170, 2048-dft slice/scaling);
(e) root-cause the UL multi-antenna combine in `vrtsim.c`.

### rev-5 addendum 3 (17:30) — 273-PRB (100 MHz) PUSH: datums + two more fixes
- **106×1 DATUM (after liboran rebuild): FH 635.7 measured, UL 7.347 wall → 29.4 Mbps sim** (2× the 51
  rate — UL scales ~0.27 Mbps/PRB with min_grant_prb ✓), ul_sym 100%, loss 3.3% (slightly overdriven
  iperf — re-measure for the clean quote). NOTE: attach succeeded right after rebuilding
  `liboran_fhlib_5g.so` from the working tree (old lib was 06-07 13:08) — rebuild-delta vs luck not
  isolated; the OPEN-2 "wire zeros" did NOT reproduce post-rebuild.
- **`sweep_iq_width.sh` RIV bug FIXED:** `275*(BW-1)` is invalid for L>138 (38.214 two-branch encoding);
  at 273 it computed 74800 — correct is **1099**. Two-branch formula now in the script.
- **273-PRB BLOCKER FOUND + FIXED: the O-RAN "numPrbc=0 = ALL PRBs" convention.** numPrbc is an 8-bit
  field; at N_RB>255 the DU's xran (correctly) sends full-band U-plane sections with num_prb=0. The RU's
  U-plane validation (`oaioran_ru.c` ~683) treated num_prbu==0 as malformed → **dropped 653,828 DL
  packets/run** ("[ORU] Drop invalid U-plane packet ... num_prb=0 nDLRBs=273") → UE saw zero SSB energy.
  Fix: translate `num_prbu==0 → nDLRBs - start_prbu` before validation; rebuilt liboran_fhlib_5g.
  First 273 run also proved: N_RB 273 inits clean end-to-end (DU 4096-FFT, RU nDLRBs 273, UE 122.88 Msps),
  NO sec_desc storm, races=1 — the 100 MHz stack is real-time-healthy at ts=0.25.
- `ORU_PRACH_UPLANE_DEBUG` now compiled into liboran (bounded prints, mirrors the DU's
  GNB_PRACH_UPLANE_DEBUG) — RU PRACH send-side src/dst visibility for future PRACH debugging.
- 273 advance: `VRTSIM_TX_ADVANCE=65536` (533 µs sim lead at 122.88 Msps).

### ★★ rev-5 addendum 4 (17:55) — **273-PRB / 100 MHz ATTACHED. FH 1.62 Gbps measured, UL 67 Mbps sim.**
`273×1 iq9: status=ok ue=10.0.0.8, FH_total=1623 Mbps MEASURED, UL=16.77 wall → 67.1 Mbps sim,
jitter 0.154 ms, ul_sym 99.76%.` (Loss 67% = iperf overdrive at 100M-wall offer; clean-rate re-run in the
iq sweep. UL ≈ the 0.27-Mbps/PRB scheduler line: 24→6.1, 51→14.1, 106→29.4, 273→67.)
**The two 273 blockers were BOTH the same O-RAN spec point — `numPrbc` is an 8-bit field, so at
N_RB>255 full-band sections are encoded as numPrbc=0 ("ALL PRBs"). The lab's custom RU (written when
106 was the ceiling) treated 0 as malformed in BOTH directions:**
1. **DL:** RU U-plane validation dropped every DU packet ("Drop invalid U-plane ... num_prb=0
   nDLRBs=273", 653,828/run) → no SSB → no sync. Fix: translate 0 → nDLRBs−start before validation
   (`oaioran_ru.c` ~683).
2. **UL:** RU C-plane parse cached numPrbc=0 verbatim into pusch_config → UL send sliced ZERO PRBs →
   valid-but-empty symbols → gNB "MSG3 ULSCH with no signal" ×4923 (RAR loop ×644). Fix: same
   translation at the section-type-1 parse (`oaioran_ru.c` ~865).
Both fixes in `liboran_fhlib_5g.so` (rebuilt; backup `liboran_fhlib_5g.so.bak_predbg` = pre-fix).
**Bring-up ladder for the record:** run1 = all-DL-dropped; run2 (+DL fix) = sync✓ SIB1✓ PRACH✓ RAR✓
Msg3 dead; run3 (+UL fix) = ATTACH + iperf. One protocol rung per fix — no other 100 MHz issues:
N_RB 273 inits clean (DU 4096-FFT/122.88 Msps, RU nDLRBs 273, UE ✓), NO sec_desc storm (stock
FRAGMENT=7 survived), races=1, ts=0.25 holds real-time.
**RUNNING:** the deliverable IQ sweep `WIDTHS="9 16"` at 273×1, IPERF 15M-wall (=60M sim, just under
capacity) → FH load (iq9 vs iq16), FH latency (lead/late/sym%), UL throughput at 0%-loss target.

### ★ rev-5 addendum 5 (2026-06-10 01:00) — 273-RB IQ-WIDTH SWEEP: FINAL TABLE + the DU per-slot wall

| iq width | comp | B/PRB/sym | B/symbol | result @ts=0.25 | FH meas (sim) | FH hand-calc | UL sim @0% loss |
|---|---|---|---|---|---|---|---|
| **8** | BFP | 25 | 6,825 | ✅ | **1449.9** | 1452 (0.14%) | **57.0 Mbps** |
| **9** | BFP | 28 | 7,644 | ✅ (3 runs) | **1623.3** | 1623 (exact) | **58–60 Mbps** |
| 10 | BFP | 31 | 8,463 | ❌ xran_queue assert | — | (1796) | — |
| 12 | BFP | 37 | 10,101 >MTU | ❌ xran_queue assert | — | (2139) | — |
| 14 | — | — | — | script-rejected (no xranlib kernel) | — | — | — |
| 16 | none | 48 | 13,104 >MTU | ❌ xran_queue assert | — | (2776) | — |

**Mechanism (one wall, not three):** the DU's per-slot processing budget at 273 RB/ts=0.25 saturates
JUST ABOVE iq9. +11% bytes (iq10) → `DevAssert(xran_queue_length==0)` (oaioran.c:545 — slot jobs
accumulate faster than the TTI-skip recovery drains). iq12/16 additionally exceed the 9600 MTU
(>1 packet/symbol → ~2× per-packet TX cost) and die faster. NOT wire bandwidth (≤700 Mbps wall at ts);
NOT protocol; the assert is a debug-build hard-stop (DevAssert) — release builds would limp with skips.
(iq10's first-run "16,918 TTI-skips, no assert" was the stale-epoch confound — fresh-epoch re-run
died with the same assert as 12/16. Codec exonerated: xranlib HAS case-10 kernels.)
**FH model validated to <0.2%:** `N_ant × (N_PRB × B/PRB/sym × 28000 × 8 × 66/70 + 8.4 Mbps hdrs)`
(66/70 = TDD active-symbol share for tdd_period 5 = 46 UL + 20 DL of 70; headers ≈ 40 B/pkt @ 26.4k pkt/s).
Matches measured at 24/51/106/273 ×1/2/4 within 0.15% (5 of 6 cells; the 24×1 outlier = different counter).
**⚠️ ts=0.125 IS BROKEN on this tree** — both iq12 and iq16 at 0.125 hit a NEW failure: ~26k
"Received Time doesn't correspond" races + ~17k TTI-skips, no assert, DU survives but timing is
disordered. Some FH-timing comparison does not scale below ts=0.25 (0.25/0.5 are the only validated
dilations). Deep dilation is NOT a usable mitigation until that's found.
**Conclusions:** (1) usable widths at 273 = **8 and 9** — compression is MANDATORY at 100 MHz on a
9.6K-MTU FH, and this DU also can't sustain >iq9 per-slot cost at ts=0.25; (2) the 9th bit costs 11%
FH for ~5% UL gain (57.0 → 59.8); (3) untested remaining mitigation for iq≥10: expand DU
`fhi_72.worker_cores` (parallelize the per-packet TX cost). Epoch-per-trial fix now in
`sweep_iq_width.sh` (stale-epoch multi-leg confound eliminated). Follow-up runner:
`run_273_followup.sh`; sweep dirs `logs/mimo_sweep/273_iqbits_193404` + `273_{A,B,C}_*`.

### rev-6 (2026-06-10 ~18:00) — worker cap; libxran rebuild scare (resolved); ★ PRACH PHASE-RACE (the real OPEN-2)
- **Worker expansion DEAD as-shipped:** `xran_spawn_workers` hard-rejects Cat-A/1-port above total=3
  cores ("unsupported configuration ... total_num_cores = 4|5" at xran_main.c:2619 pre-check) ⇒ max
  2 workers. iq≥10 @273/ts=0.25 is NOT runnable by any config lever; only code-level paths remain
  (patch spawn table / optimize TX / accept iq8-9).
- **libxran rebuild scare RESOLVED:** rebuilding libxran from source (FRAGMENT=16) coincided with
  PRACH failure, but the restored 06-07 binary failed identically ⇒ rebuild exonerated, "lost
  uncommitted xran fix" theory dead. Both libs now interchangeable; backup `libxran.so.bak_20260610`.
- **★ the real OPEN-2: PRACH-extraction PHASE RACE (run-level all-or-nothing).** iq9@273:
  yesterday 4/4 attach, today **0/6** — identical binaries, identical params (N_TA 1600, Ncp 1936,
  dftlen 4096, prach 130/−156 byte-for-byte in good vs bad logs). In failing runs the RAW debug
  window sees DENSE preamble energy while `rx_nr_prach_ru_internal`'s output (`prachF`) is ALL-ZERO
  **in the same call at the same computed address** (slot_start+336 = fft_start ✓), proven by zero
  `[RAR DEBUG] ORU PRACH TX` prints (gated on prach_has_nonzero). ⇒ divergence is RUNTIME, not config:
  leading theory = race vs the vrtsim south-reader's destructive zeroing wave in `ru->common.rxdata`;
  the writer/reader phase locks in at client-connect alignment ("client RX aligned to frame boundary",
  varies per launch) ⇒ whole runs are good or bad, clustering by day = launch-phase luck.
  **Next step (needs explicit go: nr-oru REBUILD risk):** instrument `rx_nr_prach_ru_internal`
  (nr_prach.c — print first-nonzero of DFT input+output + a post-extraction re-read of the same
  window, bounded count) + rebuild nr-oru (binary untouched since 06-05; back it up first).
  Alternatively: re-launch-until-good-phase (works, ugly — yesterday's datums were collected that way
  unknowingly).
- **STATUS of "iq9-16 @273 runnable":** iq8/9 = YES in principle (validated datums) but gated by the
  phase race per launch; iq10-16 = NO at ts=0.25 (compute wall + worker cap + MTU + no iq14 kernel).

### ★★ rev-7 (2026-06-10 evening) — THE PER-LAUNCH LOTTERY ROOT-CAUSED IN SUBSTANCE: vrtsim-alignment
### residue corrupts the RU's air-buffer addressing; THREE symptom faces, ONE defect. Plus 2 real fixes.
**Fix 1 (REAL, keep): RA warm-up race.** Stock OAI ignores ALL preambles until 100 PRACH occasions
calibrate the noise floor (`prach_energy_counter == NUM_PRACH_RX_FOR_NOISE_ESTIMATE`), and conf
`preambleTransMax` is the ASN.1 INDEX (7 = n20 — why UEs always gave up after exactly 20). Fix (now in
`run_rafix.sh` preflight, promote everywhere): **preambleTransMax 7→9 (=n100)** + `prach_dtx_threshold
150→100`. Proven: a 24-PRB run sailed RACH→RRC→NAS RegistrationComplete.
**Fix 2 (REAL, keep): SMF 30-h hang** — UE registered but PDU Session Accept never came; CN restart
(documented remedy) applied. Watch CN uptime before quoting "attach fails".
**THE LOTTERY (the remaining defect, run-level all-or-nothing, set at launch):** the RU's PRACH/air
extraction reads a CONSTANT WRONG OFFSET of `ru->common.rxdata`, decided by the per-launch vrtsim
client/server alignment ("client RX aligned to frame boundary current_sample=X aligned_sample=Y" — the
residue between vrtsim ring frame-zero and the XRAN_TIME_EPOCH frame numbering). Three faces, all
observed, all run-constant: (a) **UL junk**: idle PRACH wire carries 305-309/336 nonzero junk from
frame 0 → gNB calibrates I0≈300 (vs 0-25 clean) → real preambles (~420) can't clear I0+thres → RAR
never (today's 24-PRB mode; GOOD runs show 2/336 idle + I0≈25); (b) **UL zeros**: extraction probe
`[PRACH EXTRACT STAT] calls=84000 all_zero=84000`, wire 0/336, gNB 0.0 dB (273 mode); (c) **DL bad**:
UE never syncs (no preamble ever sent; RAW+probe both zero — consistent). Faces (a)/(b)/(c) chosen per
launch ⇒ "yesterday 4/4, today 0/12" was alignment luck, not days.
**Root-cause target (code):** nr-oru south-reader ↔ PHY rxdata index mapping at vrtsim connect
(`executables/nr-oru.c` get_timestamp/sync_params/initialize_sync_params + the "aligned to frame
boundary" client init in vrtsim.c). Compare aligned_sample residue vs XRAN frame-zero in good vs bad
launch logs — the offset should equal the junk/zero displacement.
**Probe (kept, compiled into nr-oru):** `[PRACH EXTRACT]`/`[PRACH EXTRACT STAT]` in
`rx_nr_prach_ru_internal` (nr_prach.c, prints energetic extractions only; needs RU phy_log_level=info).
nr-oru backup pre-probe: `build/nr-oru.bak_20260610`.
**Loop verdict ("iq9-16 @273 runnable?"):** iq8/9 — runnable ONLY via launch lottery until the
alignment defect is fixed (validated datums stand: FH 1450/1623 Mbps, UL 57-60 sim); iq10-16 — NO at
ts=0.25 (DU per-slot wall; xran worker cap ≤2 for Cat-A/1-port; MTU>9600 for 12/16; no iq14 kernel).
**Next session:** (1) promote RA fix + CN-age check into run_matrix/sweep preflights; (2) root-cause
the alignment residue (compare good/bad "aligned_sample" values); (3) optional early-detect gate:
bad launches are identifiable within seconds (idle wire 305/336 vs 2/336, or DU I0 at counter=100).

### rev-8 (2026-06-10 ~20:30) — grid-snap experiments NEGATIVE; today-bias suspected BOX-STATE DECAY; REBOOT prescribed
- **Grid-snap fix tried BOTH directions in `perform_initial_sync` (nr-oru.c): floor → kills DL
  outright** (writes shifted into ring past → TOO_LATE: residue −37,216 = 9.7 ms-wall late/write,
  no sync); **ceil → 0/3 at 24-PRB** — but the same-day baseline is ~0/12, so ceil is
  inconclusive-to-negative, NOT disproof of the grid theory. **Snap REVERTED**; the per-launch
  residue is now LOGGED measurement-only ("ORU initial sync: ring sample X (frame-grid residue R
  of SPF)", LOG_A(PHY), needs RU phy=info) → correlate R with good/bad faces offline.
- **Today's dominant variable is suspected BOX-STATE DECAY:** 33 h uptime, ~80 stack launches,
  ~100 hugepage alloc/free cycles since boot. Yesterday post-reboot: 4/4 attaches; today: ~1/19
  (only v3-legA reached registration). The lore already prescribes reboot for wedged
  DPDK/SR-IOV/cgroup state. **PRESCRIPTION: reboot → prepare_network → CN up → MAC assert →
  re-run `run_snap_validate.sh`** (now = probe-only binary + RA-fix preflight; expects k≥2/3 at
  24 if decay was the bias). Binaries in place: nr-oru (probe + residue log, snap reverted, backup
  `nr-oru.bak_20260610` = this morning's), liboran (numPrb fixes + PRACH debug), libxran (either —
  proven interchangeable).
- Keep separate: the per-launch lottery (alignment residue theory ALIVE, untested cleanly) vs the
  day-scale bias (reboot variable). Post-reboot, residue-vs-face correlation on a healthy box is
  the clean experiment.

---

### ★★ rev-9 (2026-06-11 ~11:00) — REBOOTED; BOX-DECAY hypothesis FALSIFIED; **273 HEALTHY 3/3**; UL-fail mechanism = CRC-fail-at-good-SNR
Post-reboot bring-up clean (VFs/MACs `64:66-69`/hugepages 8192/CN 8-8 healthy fresh). Ran `run_snap_validate.sh` (3×24 + 3×273 iq9, ts=0.25, RA-fix, probe-only nr-oru):
- **24 PRB = 1/3** attach (trial1 ok but UL≈0; trials 2,3 ue-timeout though trial-2 reached `RegistrationComplete`). **273 PRB = 3/3** attach, **FH 1623 Mbps (=model), fh_late=0, fh_lead 9-12, UL 13.5/13.2/13.9 @ 0% loss.**
- **BOX-STATE-DECAY hypothesis (rev-8) FALSIFIED:** a *fresh-rebooted* box still shows the small-BW lottery. The fault is structural (timing/alignment), NOT uptime decay. Box exonerated; reboot is NOT the fix.
- **24-PRB UL failure mechanism PINNED — it is NOT "UL-zeros":** gNB PHY ground-truth `ULSCH NAK ... crc_valid 0 abort 1 ... SNR 33.3 dB` (and 12-16 dB). UL signal PRESENT with good SNR but **every TB fails CRC** = sample/timing **misalignment** (UE-side `Deadline missed for tx slot ... missed by 185`, `TAest -1`). Control-plane UL (Msg3/RRC/NAS) is robust enough to squeak through → attach sometimes completes; data-plane PUSCH fails once TA drifts. Low-BW is MORE sensitive because the per-launch residue is a fixed *sample* count = larger *fraction* of a subframe at 15 Msps (24-PRB) than at 123 Msps (273). Residue datums (random, no clean N=3 correlation): t1=11580 (only attach, smallest), t2=129553, t3=46482 of 153600.
- **TWO reporting/measurement traps DEBUNKED:** (a) summary.csv `ul_rb=24` at 273 is a **parser bug** — it reads `*.conf.orig` (the pre-`BW_PRB` baseline); the ACTUAL run used **273-PRB UL** (DU log `rb 0+273` ×32, `N_RB_DL 273`). (b) UL "only 13.9 Mbps" at 273 = **iperf offered-rate-capped at `IPERF_UDP_RATE=15M`** (90% delivery), NOT a BWP/channel cap. Real capacity is the 06-10 ~57-67.
- **NEW ASSET `run_iq_sweep.sh`** — 273-PRB IQ-width sweep (iq {8,9,10,12,16}), per-width run_snap_validate preflight, UL offered **80M** UDP to find true capacity, harvests `sweep_table.csv` (fh_total/fh_rx/fh_tx, fh_late, fh_lead, ul_mbps, ul_loss, snr). RUNNING at rev-9 write-time → results pending (the original `/loop iq9-16 runnable` question + FH-load/latency/UL-vs-width table).
- OPEN carried forward: small-BW lottery (CRC-fail mechanism now named); iq≥10@273 per-slot wall (testing now); UL chanmod multi-ant scaling (AGC workaround).

### ★★★ rev-10 (2026-06-12) — IQ-SWEEP VERDICT iq8/9-only; iq10 verdict WITHDRAWN→retested; BAD-DAY RETURNED; **PRACH-DROP MECHANISM TRACED TO Ta4 WINDOW (test running)**
**06-11 IQ sweep (273, ts=0.25, UL 80M UDP):** iq8 ✅ FH 1450 / UL 62.8 sim; iq9 ✅ FH 1623 / UL 59.3 sim (UL flat ⇒ air-limited, FH scales with width); iq10 ❌ soft desync; iq12/16 ❌ hard crash `DevAssert(xran_queue_length==0)` @DU + `Assertion (buf)` @RU (10101/13104 B > 9600 MTU, 2-frag; iq16 compMeth 0). iq14 = no xranlib kernel. **User challenged "iq10 should pass" — vindicated:** its TTI skips started at slot **0.10 (before any traffic)**, 0 PRACH, FH healthy (lead 12) = cold-start face, NOT compute; BFP-10 kernel EXISTS (`case 10:` ×8 in xran_compression, same as 8/9/12); fits 1 MTU (8463 B). 06-10 "iq10 dead" evidence contaminated (stale-epoch + decay-day). **iq10 retest 06-12: canary iq9 FAILED → day-bias → no iq10 verdict (0/4 day: canary + iq10×3, two faces: canary=PRACH-drop, iq10 legs=DL-no-sync).**
**THE BAD DAY RETURNED (06-12, 28 h uptime, load ~1 vs 0.08):** 273 went 5/5 (06-11 fresh box) → 0/4 (06-12). Day-scale bias is REAL for 273 (rev-9's falsification only covered the 24-PRB CRC face on a fresh box — different face).
**Residue correlation DEAD:** good 273 runs residue/SPF ∈ {.354,.563,.637,.643,.871}, bad ∈ {.062,.680} — no threshold/clustering. The initial-sync frame-grid residue does NOT predict the face; rev-7's alignment theory dead in its simple form.
**PRACH-drop face FULLY TRACED (06-12 canary forensics, iq9):** UE syncs+SIB1 ✓, sends 200 preambles ✓ → RU extraction probe: `src_nz=4064/4096 src_e=21821 out_nz=139/139` ✓ NONZERO → memcpy verbatim into `prach_item.rxsigF[0][aa]` = exactly what `write_prach` sends (nr-oru.c:521-531, same thread; nr_prach.c:380) → `xran_oru_send_prach` abort paths ("not configured"/"cache corruption" LOG_W) = **0 hits** → mbuf built fresh+memset+filled+sent ✓ → **DU `[gNB PRACH RX]` receives ZEROS/nothing: only the first-10-cap prints (all frame 2, idle), NEVER a nonzero payload** despite 200 hot preambles. gNB RAPROC 0.0 dB ×6342 forever. Meanwhile PUSCH U-plane on the same wire: 25,088 pps / 1131 Mbps in BOTH good+bad runs.
**Mechanism (test running):** DU xran UL U-plane acceptance window **`Ta4 = (400, 440)` = 40 µs, "min not used in xran, max yes"** (oran-config.c:1027) — only LATE drops. PRACH is sent AFTER 12×4096-pt DFTs (compute latency, load-dependent); PUSCH is forwarded phase-locked (always in-window). Per-launch thread phase ⇒ PRACH lands in/out of window for the WHOLE run (run-constant face ✓); ts=0.25 dilation makes the window effectively 4× narrower in sim-time (~10 µs) ✓ 273-only (dftlen 4096 vs 512 at 24) ✓ day-bias = load/uptime shifting DFT latency across the 40 µs cliff ✓. **GOOD-run "junk every occasion" debunked:** post-attach PUSCH energy bleeding into the slot-19 PRACH window (~257 occasions) — normal.
**TEST: `run_ta4_test.sh`** — 3×273 iq9 identical to the failing canary except `Ta4 (400,440)→(100,1760)`. ≥2/3 ⇒ proven (promote widened Ta4 to all runners + re-verdict iq10 on fixed box); 0/3 ⇒ falsified (next: liboran send/recv counters rebuild).
**Misc:** summary.csv `ul_rb` parser bug (reads pre-mutation `.orig`); UL @273 was 15M-offer-capped in snap runs (real ~60 sim); CN restarted 06-12 (was 25 h ≈ SMF hang window). Assets: `run_iq_sweep.sh` (per-width sweep, 80M UL), `run_ta4_test.sh`.

### ★★★★ rev-11 (2026-06-12 ~12:30) — **Ta4 MECHANISM PROVEN 3/3 ON THE BAD DAY. ATTACH LOTTERY (273 PRACH-drop face) CLOSED, CONFIG-ONLY FIX.**
`run_ta4_test.sh` result — identical harness/env to the 0/4 day, ONE change `Ta4 (400,440)→(100,1760)`:
| trial | st | UL wall→sim | DU nonzero-PRACH-RX | RAPROC nonzero |
|---|---|---|---|---|
| baseline (today ×4) | ❌ 0/4 | 0 | **0** | 0 |
| t1 | ✅ ok | 15.17→60.7 | **2840** | 43 |
| t2 | ✅ ok | 7.63→30.5 | **3734** | 592 |
| t3 | ✅ ok | 15.06→60.2 | **2735** | 44 |
The mechanism observable (DU-side nonzero PRACH U-plane arrivals) flipped 0→~3k — the dropped packets are being **admitted**, not luck. **CLOSED:** 273 attach lottery = RU PRACH U-plane (sent after 12×4096-pt DFT extraction, latency load/phase-dependent) lands beyond `Ta4_max=440 µs` → xran DU RX silently drops → gNB PRACH 0.0 dB forever. Day-bias = load/uptime modulating DFT latency across the 40 µs cliff (fresh box 5/5, 28 h+load~1 box 0/4). **Fix promoted** into `run_iq_sweep.sh` preflight; ⚠️ promote into run_matrix.sh / fh_sweep_vrtsim.sh / run_snap_validate.sh / run_rafix.sh preflights when next used. Stock conf untouched (preNoBFPprach_bak pristine; sed applies per-run). t2's lower UL (30 vs 60 sim) unexplained — single sample, not chased.
**Residual OPEN:** (a) iq10@273 re-verdict — running now 3× with Ta4 fix (today's Ta4 3/3 = the iq9 canary); (b) 24-PRB CRC-fail-at-good-SNR face (different mechanism: UE tx-deadline misses / TA drift at 15.36 Msps — NOT Ta4: 24's dftlen=512 is fast); (c) UL chanmod multi-ant scaling (AGC workaround); (d) t2 UL dip; (e) day-bias *for the 24-face* unmeasured.

### rev-12 (2026-06-12 ~13:00) — **iq10@273 FINAL VERDICT: NOT RUNNABLE (clean evidence). IQ-width question CLOSED: cutoff = iq9.**
3× iq10 with Ta4 fix, same-day iq9 control 3/3: **0/3.** All trials: FH transports the FULL iq10 rate (1797.9 Mbps = model ✓, late ≤2, lead 12) — the fabric is fine — but the DU **chronically misses per-slot deadlines** (TTI skips 13,932 / 14,279 / 3,650 — vs iq9's ~95 startup-only) and the slot-clock slip kills the time-keyed PRACH path: UE syncs + sends 100 preambles (t1/t2), **DU nonzero-PRACH-RX = 0 even with Ta4=1760 µs**. t3 worse draw (UE 1 sync, 0 preambles, ul_sym 69.7%). Distinct from the (withdrawn) cold-start story AND from the iq12/16 crash: iq10 sits *just past* the per-slot budget edge — survives, slips, never attaches. Mitigations exhausted at config level (workers hard-capped 2 @ Cat-A; deeper ts broken; MTU not implicated). Remaining = code-level only (DU packing-path optimization / xran spawn-table patch) — OPEN, deprioritized.
**FINAL IQ-WIDTH TABLE @ 273/ts=0.25:** iq8 ✅ FH 1450, UL ~63 sim · **iq9 ✅ FH 1623, UL ~60 sim** · iq10 ❌ per-slot slip (this rev) · iq12 ❌ crash (2-frag>MTU + queue assert) · iq14 ❌ no xranlib kernel · iq16 ❌ crash (uncompressed 13104 B). **Cutoff = BFP-9 — matching commercial 100 MHz O-RAN practice.** The user's "iq10 should pass" challenge didn't change the verdict but forced out the contaminated evidence and en route delivered the Ta4 root-cause (rev-11) that closed the 273 attach lottery.

### ★★★★ rev-13 (2026-06-13) — 2-PHYSICAL-PORT FABRIC + **THE TTI-SLIP MECHANISM FOUND & FIXED** (producer/consumer race, NOT compute). iq10 re-test running.
User rewired to **2 real ports over a DAC**: RU VF `06:02.0`@eno1np0(05:00.0, MAC 64:66) ↔ wire ↔ DU VF `06:0a.0`@enp5s0f1np1(05:00.1, MAC 64:68). Every FH packet now crosses the wire (dst MAC non-local to the egress PF ⇒ VEB pushes to port) — the same-PF VEB short-circuit is gone. **Proven on wire:** PF HW counters `port0.tx_unicast == port1.rx_unicast` exactly (1,327,416), FH full rate.
- **Raw-PF DPDK is IMPOSSIBLE on this box w/o reboot:** uio_pci_generic refuses the X710 PFs (INTx), vfio-pci fails — both PFs share **IOMMU group 15** with SATA/USB/mgmt-NIC (no ACS; `testpmd`="No probed ethernet devices"). So use **VF-based** 2-port (1 VF/PF). Also: X710 is at **PCIe gen3 x1** (dmesg warns "insufficient bandwidth") — fine for dilated FH (~450 Mbps wall) but the x1 DMA contention is what makes U-plane bursty.
- **Box-prep (manual, post-rewire):** kill stacks → `nmcli dev set <pf> managed no` BOTH PFs (else NM DHCP-cycles enp5s0f1np1 every 45 s and bounces the VF) → `disable_ipv6` → `sriov_numvfs` 0 then 1 each PF → set VF MAC/spoofchk-off/trust → `udevadm settle; sleep 8` → bind both VFs uio. i40e PF IRQs already on 0-3 (irqbalance off) — no re-pin needed. ⚠️ A competing shell that zeroed `sriov_numvfs` mid-run pulled the VFs out from under the stack (attempt-1 false fail) — coordinate exclusive NIC ownership.
- **★ THE TTI-SLIP MECHANISM (this is the big one, reframes iq10/12/16):** `oaioran.c:514 xran_fh_rx_read_slot` — the xran RX callback (`oai_xran_fh_rx_callback`, fires per slot at symbol-7 U-plane arrival) PUSHES one `oran_sync_fifo` event; the DU L1 PULLS one/slot. When U-plane arrives **bursty** (real wire + shared gen3-x1 DMA), the queue backs up; at `MAX_QUEUE_LENGTH_NO_JUMP` (hard-coded **3**, real-time-HW value) it **jumps-to-latest + `DevAssert(xran_queue_length==0)`** → DL/PRACH desync. It is a **producer/consumer race, NOT the Ta4/T1a packet windows** (those gate individual packets; flow-control already off, IRQs clean). The iq10-VEB "compute wall" (13.9k skips) and iq12/16 crash (queue won't drain → assert fails) are the SAME mechanism at higher per-slot byte load.
- **★ THE FIX (config-grade, reversible):** made the threshold env-tunable `OAI_FH_MAX_QUEUE_NO_JUMP` (default 3 ⇒ stock behaviour unchanged), bound `<10` (= `XRAN_N_FE_BUF_LEN`/2 = the half-ring buffer-reset horizon, else read buffer clobbered). `oaioran.c` rebuilt → `liboran_fhlib_5g.so` (backup `.bak_pre_qjump`); env threaded via `run_du.sh` + `run_iq_2port.sh`. **At q=8: 2-port iq9 skips 1654→10 (startup-only), UE FULLY ATTACHES** (4-step RA ✓, RRCSetupComplete ✓, **Registration Accept+Complete** ✓, UL PHY **crc_valid 1 @ 38.8 dB, rb 0+273** ✓). Residual gap = PDU-session establish stalled (SMF logged nothing; CN restarted, UE_WAIT→420).
- **⇒ iq10 VERDICT (rev-12 "NOT runnable") IS UNDER RE-TEST:** if q=8 also lifts iq10 (its VEB failure was the same producer bunching), the **BFP-9 cutoff may not be a hard wall** — it may be the real-time skip threshold. Running now: iq9-control + iq10×3 on 2-port, q=8, fresh CN. [RESULT PENDING — see rev-14]
- **Assets:** `run_iq_2port.sh` (2-port runner: NM-aware MAC assert, conf rewrite to one_vf_cu_plane single-device, q-jump env, Ta4 fix), `prepare_2port.sh` (raw-PF, abandoned). Knob: `OAI_FH_MAX_QUEUE_NO_JUMP`.

### ★★ rev-14 (2026-06-13) — iq10 VERDICT **CONFIRMED ON CLEAN EVIDENCE: NOT RUNNABLE.** BFP-9 cutoff holds; the slip-race was a *separate* confound (now fixed).
2-port, q=8, fresh CN, controlled batch [iq9 control + iq10×3]:
| leg | status | FH (sim) | UL (sim) | TTI skips |
|---|---|---|---|---|
| iq9 control | ✅ **ok** | 1623 | 14.49 wall→**58** | **1** |
| iq10 ×3 | ❌ ue-timeout | 1798 (full rate ✓) | 0 | **18985 / 20887 / 20892** |
**The q=8 fix that cut iq9 to 1 skip did NOTHING for iq10 (~20k skips, ~1 per slot).** Two DISTINCT mechanisms, now separated: (a) iq9-on-2-port slip = *bursty* producer (wire+gen3-x1 DMA) → q=8 absorbs ✓; (b) iq10 slip = *sustained* — the DU L1 can't decompress+process 273×iq10 U-plane within even the 4×-dilated slot budget, so the FIFO maxes every slot regardless of depth. FH transport is fine (full 1798 Mbps received); it's DU per-slot CONSUMPTION that's the wall. **This is the rigorous confirmation the user's "iq10 should pass" challenge demanded: with the real-time-skip artifact isolated AND removed (proven by iq9 flipping to ok on the same fabric/CN/run), iq10 STILL fails.** rev-12's verdict stands, now on uncontaminated evidence. **Net gains from the challenge:** (1) found+fixed the producer/consumer slip race (`OAI_FH_MAX_QUEUE_NO_JUMP`, real bug, helps marginal configs); (2) brought up + characterized the 2-port wire fabric (works at iq9, VEB was lower-latency); (3) iq10 wall reclassified from "DU per-slot budget (vague)" to specifically **DU L1 decompress+decode throughput per slot**. iq10 would need real DU-side optimization (faster BFP decompress / more L1 parallelism), not a config knob. **FINAL CUTOFF @ 273/100 MHz/ts=0.25: BFP-8 and BFP-9 only.**

### rev-15 (2026-06-13) — FULL iq{8,9,10,12,16} SWEEP ON 2-PORT WIRE (q=8, Ta4 fix): cutoff + mechanisms reproduced EXACTLY vs VEB.
| iq | status | FH(sim) | UL wall→sim | skips | mechanism (log-confirmed) |
|---|---|---|---|---|---|
| 8 | ✅ ok | 1450 | 12.6→50 | 1 | — |
| 9 | ✅ ok | 1623 | 15.0→60 | 1 | — |
| 10 | ❌ | 1798 (flows) | 0 | 20793 | DU-L1 wall: DevAssert=0, buf=0, FH-steady=YES (FH fine, L1 can't consume) |
| 12 | ❌ | 0 (died) | 0 | 703 | MTU crash: RU `Assertion(buf)`=1 + DU `DevAssert(queue==0)`+Exiting=1 |
| 16 | ❌ | 0 (died) | 0 | 1874 | MTU crash (compMeth 0 uncompressed 13104B); same asserts |
iq8/9 = 1 skip each (q=8 absorbs the wire burst), UL 50/60 sim, SNR 38.8 dB. **The two walls (iq10 + iq12/16) are FABRIC-INDEPENDENT — identical signatures on VEB and real 2-port wire.** Definitive: BFP-9 is the 100 MHz cutoff. Sweep log: `logs/iq2port_20260613_114248/sweep_table.csv`.

### ★★★ rev-16 (2026-06-13) — iq10 WALL PROFILED — **CORRECTS rev-14: it is NOT decompress/compute, it's a SPIN-WAIT on late U-plane (single core).**
`perf record` 10 s on the 8 DU cores during a live iq10 run (102,970 samples) — hard data, overturns the "DU-L1 decompress+decode throughput" claim:
- **Single-thread bottleneck:** cores 4/5/6/8 are **93–98% IDLE**; **core 7 = 94.6% busy**. DU is NOT out of CPU — one thread is the serial wall.
- **Core 7 = 93% in `xran_fh_rx_read_slot`** (OAI's FH-consume fn, `oaioran.c`). `oai_bfp_decompression` = **1%**. So decompression is NEGLIGIBLE — rev-14 was wrong.
- **`perf annotate`:** the hot instructions are `pause` + volatile `movzwl (%rdi)`/`test` = the **spin-wait at `oaioran.c:663`** (`for w<300000 && *ns==0: pause`). The consumer SPINS waiting for the tail symbols' (sym 10-13) U-plane fragments to land in the read buffer.
- **Mechanism:** at iq10's higher per-slot byte rate the tail U-plane arrives too late; the per-slot spin exceeds the dilated 2 ms slot budget; single-threaded ⇒ falls behind cumulatively ⇒ 20.8k jumps ⇒ no coherent DL ⇒ no attach. FH *bytes* flow full rate (1798 Mbps) ⇒ it's a **delivery TIMING/ordering limit in the xran RX path, NOT bandwidth or compute.** OAI's own comment at oaioran.c:655-659 corroborates: "~71% of a multi-symbol PUSCH's REs absent from the read buffer per slot … upstream of this read (xran RX buffer rotation/timing)."
- **"DU or XRAN?" = the HANDOFF:** CPU burns in the DU (OAI consumer spin, `xran_fh_rx_read_slot`/`oaioran.c`, 1 core); it spins because xran RX can't deposit iq10's tail U-plane in time. iq12/16 unchanged = RU TX MTU assert `oaioran_ru.c:1081` (one symbol >9600 mbuf), pure OAI nr-oru.
- **⇒ iq10 fix is NOT "faster decompress/more cores"** (decode is 1%, 7 cores idle). Real levers: earlier tail-symbol delivery (xran RX buffer-rotation timing / advance RU UL TX) or de-serialize the consumer so a slow slot doesn't block the next. Code changes in the OAI↔xran RX boundary, not config. Profile: `/tmp/iq10_du.perf`.

### ★★★ rev-17 (2026-06-14) — DEEP-DILATION TEST (clean, at runnable widths) — **ts=0.125 is NOT broken; iq10 wall is DILATION-INVARIANT (refutes rev-16's headroom framing).**
Ran the control that history never had — ts=0.125 at a RUNNABLE width (not iq12/16). 2-port, q=8, scaled waits (UE 900s):
| width | ts=0.25 skips | **ts=0.125 skips** | ts=0.125 'Received Time' races |
|---|---|---|---|
| iq9 | 1 (ok) | **1 (ok, UL 8.36 wall→67 sim)** | **1** |
| iq10 | 20793 (fail) | **19588 (fail)** | **25786** |
- **DEBUNK #1 — "ts=0.125 BROKEN / ~26k races" (rev-6/memory) WAS DOUBLY CONFOUNDED:** it was only ever tested at iq12/iq16 (MTU-broken), and the "26k races" are the **WIDE-IQ wall itself** (iq10@0.125 = 25,786 races; iq9@0.125 = 1). **ts=0.125 is a VALID dilation at runnable widths.** Corrects "only 0.25/0.5 validated."
- **DEBUNK #2 — rev-16's "post-tail HEADROOM" model is REFUTED:** iq10 fails IDENTICALLY at 2× wall-budget (20793 vs 19588). If it were a timing-budget/headroom problem, dilation would help; it does nothing. ⇒ the consumer waits for **MISSING** data, not LATE data — the tail U-plane never lands in the read buffer ("71% REs absent / buffer rotation"); spin exhausts its cap on bytes that never arrive; no wall-time conjures missing bytes. **It's a structural buffer-rotation/ordering cascade, dilation-invariant**, triggered by iq10's larger/more-fragmented U-plane tipping the deposit-vs-reset phase.
- **PLAN REPRIORITIZED (timing levers OUT, structural IN):** ❌#1 deeper-ts (refuted) · ❌#2 clock-constants (moot, ts=0.125 fine) · ⚠️#3 advance-tail-TX (only a phase shift) · ✅**#4 raise `XRAN_N_FE_BUF_LEN` 20→32 (break the rotation cascade) = NEW LEAD** · ✅#5 de-serialize consumer (real fix). Logs: `logs/iq2port_20260614_150634`.

### ★★★★★ rev-18 (2026-06-14) — **iq10 SOLVED. ROOT CAUSE = the consumer SPIN-WAIT over-reaction (a 1-line software cap), NOT a hardware/protocol wall. Cutoff moves BFP-9 → BFP-10.**
Dropped the #4-ring-rebuild guess (q=8 already keeps the consumer inside the buffer horizon, so depth wasn't it). Checked the EXISTING `ul_sym_present_pct` metric first: iq10 symbols are **69-100% present, NOT "71% missing"** → the deposit mostly works → the catastrophic part is the consumer's RESPONSE. Made the spin cap env-tunable (`OAI_FH_SPIN_CAP`, oaioran.c:663, default 300000) and rebuilt liboran. **RESULT (2-port, q=8, ts=0.25, spin_cap=2000): iq10 = ✅ OK, 0 skips, FH 1798, UL 16.58 wall→66 sim, ul_sym_present 99.98% (5000/5000=100%). iq9 control unaffected (ok, 0 skips).** iq10 went 20793-skips-dead → 0-skips-full-UL by ONE knob.
- **THE REAL MECHANISM (final, reconciles rev-16 & rev-17):** iq10's larger U-plane occasionally leaves one tail symbol momentarily un-deposited at read time → consumer spins **300000 iters ≈10 ms** (`oaioran.c:663`) → that single spin exceeds even the dilated slot budget (2 ms@0.25 / 4 ms@0.125) → slot blows → consumer falls behind → buffer rotation disorders → reads stale buffers → MORE apparent-missing → MORE spin → **runaway cascade** = the 20k skips. **The "69% missing" was a SYMPTOM of the cascade, not the cause.** Cap=2000 (~70 µs) → slot always completes → no cascade → 100% present.
- **Explains every prior dead-end:** dilation-invariant (10 ms spin > any practical dilated slot ⇒ rev-17 ✓); perf 93%-spin (rev-16) was literally the spin, but fix = "spin less" not "compute faster"; iq9 works = ~100% present ⇒ never enters the spin.
- **iq10 wall was a SOFTWARE OVER-REACTION** — a spin cap tuned for real-time HW, catastrophic under non-real-time dilation. NOT compute / timing-budget / MTU / protocol. **CUTOFF NOW BFP-10** (iq12/16 still separate = RU-TX MTU mbuf assert oaioran_ru.c:1081). **✅ CONFIRMED RELIABLE: iq10 = 4/4 ok at spin_cap=2000 (breakthrough + ×3), all 0 skips, UL 66/70/69/68 sim, FH 1798.** Knob threaded: oaioran.c → run_du.sh → run_iq_2port.sh. Logs: `logs/iq2port_20260614_200837` + `_201635`. Best-cap not swept (2000 is clean: 0 skips, 100% present, full UL — no need). **FINAL CUTOFF @273/100MHz/ts0.25: BFP-8/9/10 runnable; iq12/16 = MTU (fragmentation fix); iq14 = no kernel.**

### ★★★★★ rev-19 (2026-06-14) — **THE WALL IS GONE. ALL BFP widths 8/9/10/12/16 run at 273/100 MHz.** #1 knobs defaulted + #2 RU-TX fragmentation implemented & WORKING.
**#1 (defaults locked):** `run_du.sh` now defaults `OAI_FH_MAX_QUEUE_NO_JUMP=8` + `OAI_FH_SPIN_CAP=2000` (was 3/300000); `run_iq_2port.sh` matches; Ta4 sed already in preflight. Every runner through run_du.sh now gets BFP-10 free. Source defaults stay HW-correct (3/300000) for upstreaming.
**#2 (iq12/16 fragmentation — SOLVED):** new code in `xran_oru_send_pusch` (oaioran_ru.c, ~after data_len): when a symbol's payload > MTU, split its PRBs across N O-RAN U-plane sections (same section_id, consecutive startPrbu/numPrbu via `fill_data_section_header(dsh, cl, cs, sid)`, each ≤8192 B), reorder once into host-order local_src then per-frag BFP-compress (iq12) or htons-copy (iq16-uncompressed). **Contained: n_frag==1 (iq8/9/10) falls through the BYTE-IDENTICAL original path** (iq10 control = ok, 0 skips ⇒ no regression). RX needed NO change (xran_rx_proc.c appends sec_desc[sym][0..15]; consumer oaioran.c writes each frag at startRB offset then DC-reassembles on the band-completing frag). Rebuilt liboran + nr-oru (backup `.bak_prefrag`).
**RESULT (2-port, ts=0.25, defaults):** | iq | status | FH(sim) | UL wall→sim | skips | present |
|10|✅ok|1801|16.6→66|0|99.98%| (control, unchanged path)
|**12**|✅**ok**|**2138**|17.0→68|0|99.98%| (2-frag BFP — was DevAssert+buf crash)
|**16**|✅**ok**|**2754**|16.9→68|0|99.98%| (2-frag uncompressed — was crash)
3/3 attach (RA+RegAccept+RegComplete) each, SNR 38.8, **0 frag asserts/crashes**. FH scales w/ bytes/PRB (31/37/48 → 1801/2138/2754, model ✓); UL flat ~66-68 sim (air-capacity, FH-width-independent) across the WHOLE range.
**⇒ THE "BFP-9 HARD WALL" IS FULLY OVERTURNED.** Every standard BFP width runs at 273/100 MHz via **3 config knobs (Ta4, q-jump, spin-cap) + 1 feature (RU-TX fragmentation, ~80 lines)**. None was hardware/protocol — all OAI real-time-vs-dilation software. **Only iq14 remains: no BFP-14 kernel in xranlib** (separate xran-lib gap, not OAI). N=1 for iq12/16 (clean, deterministic — not lottery-prone); confirm w/ ×3 if desired. Logs: `logs/iq2port_20260614_203652`.

---

## ✅ 2026-06-09 (rev 4) — REBOOTED; FULL 4×4 WIDE-BW SWEEP PLAN READY → `WIDEBW_4X4_SWEEP_PLAN.md`

**Goal this session:** test wide-BW PRB (51/106) × 4×4-antenna UL in vrtsim — see how FH load + FH latency/jitter/loss change and how UE UL throughput changes. That IS the OPEN #9/#10 blocker.

**DELIVERABLE = `/home/jesse/oran_lab/WIDEBW_4X4_SWEEP_PLAN.md`** — the full executable plan. Read it to run. Contains: 10-cell sweep matrix (G0,L1,L2/A,C2,P2/B,L3/C,H1,L4/T2,L5,T1), N=5 cold-starts/cell, non-perturbing offline measurement, iso-load + chanmod-off controls, FH+UL measurement recipes, failure decision tree, two-plot deliverable (FH-load vs UL, FH-latency vs UL).

**Box (warm-rebooted ~10:12 2026-06-09):** BARE — HugePages_Total=0, VFs 06:02.0-3 UNBOUND, 5GC docker DOWN, /dev/shm clean, NO hugepage leak, no stale procs. The rev-3 NIC/VEB wedge status is **UNKNOWN** until a 24×1 attach runs — that attach (G0) is the gate. Bring-up first: `sudo DPDK_DRIVER=uio_pci_generic bash prepare_network.sh` + `cd oai-cn5g && docker-compose up -d`.

**Verified this session (corrections to the older handoff text):**
- **Harness scripts ALL present at `~/oran_lab/`** (my first shallow `find` + `rtk find` missed them): `fh_sweep_vrtsim.sh` (1-ant path, HAS the shared-epoch fix), `sweep_iq_width.sh` (MIMO path — NO epoch/timescale/min_grant handling, patches conf in place with NO restore-on-exit → must restore + re-apply `min_grant_prb` at the top of EVERY iteration), `run_{ru,du,ue}.sh`, `run_rfsim_clean.sh`, `prepare_network.sh`. devbind = `oaicicd/test_dir/dpdk-stable-20.11.9/usertools/dpdk-devbind.py`.
- **⚠️ 51 PRB is ODD → MIMO RIV/pointA/SSB arithmetic mis-centers. Use 52 (even) for ALL MIMO cells; keep 51 only for the 1-ant datum.**
- **Binaries timestamp-stale but effectively OK for attach:** `nr-softmodem` 06-06 15:35 < `len_coreset` commit (b46a6ad189) 15:54; `libxran.so` 06-07 13:07 < FRAGMENT=16 (28877f6) 14:44 — BUT the prior 06-07 51×1/106×1 attaches with this exact binary prove the wide-BW attach fix is compiled in. **Rebuild is CONDITIONAL** — only if 106×4 throws a `sec_desc` storm → rebuild libxran w/ FRAGMENT=16 in ABI order (xran → oran_fhlib_5g → nr-softmodem/nr-oru). Real xran lib path = `oaicicd/test_dir/phy-f-1.0/fhi_lib/lib/build/libxran.so`.
- **FH latency/loss signal:** xran `Rx_late` counter NEVER increments in this build (`Rx_on_time==total`). Use instead: vrtsim `Average TX budget`/`too early` (RU log, printed only on graceful SIGINT — never `pkill -9`), DU `UL sym present` %, and `TTI processing delay…skipping` counts.

### #9 — WHAT IT IS, EXACTLY (the OPEN root-cause blocker)
**Question:** why does turning ON `chanmod` (the per-antenna FIR channel model, `perform_channel_modelling` `vrtsim.c:789`, engaged only in the `NB!=1` MIMO path) cause attach to fail — RU `rxdataF` slot energy = **0** → UE `synch Failed` — as bandwidth and/or antenna count grow, and WHICH factor causes it?

**Symptom (evidence):** bare wide-BW attaches (51×1, 106×1 ✅, chanmod off); narrow-BW + chanmod survives (24×1/2/4 ✅); wide-BW + chanmod dies (52×2, 52×4 ❌; 106×4 ❌ + `sec_desc` storm). So the lethal combo is **wide-BW × chanmod**, not MIMO per se.

**Why still OPEN — three suspects covary, none isolated:** (1) **bandwidth** (samples/slot to filter), (2) **total FH load** Mbps = PRB×ant, (3) **cold-start reliability** (~50% flaky; prior FAIL labels came from only 1–2 attempts = statistically meaningless). The rev-1 claim "fails even at 1×1 / antenna-independent" was **RETRACTED** (broken forced-config). **Methodology trap:** every in-process printf perturbs the timing-sensitive cold-start and changes the outcome (`VRTSIM_IQ_DEBUG` broke even the 24×1 baseline; the old "mbuf crash" was a phantom). → measurement MUST be offline/log-parse.

**Leading mechanism (code read rev-4):** async per-aarx **actor FIFO** (`vrtsim.c:1006-1036`) + a wall-clock producer that **never waits** for the actors (`vrtsim.c:358-360`) + **silent TOO_LATE drop** (`shm_td_iq_channel.c:152-156`). FIR cost ∝ `nb_tx × samples/slot × actors`; at wide-BW/4-ant it overruns the (dilated) slot budget → the chanmod write lands late → dropped → RU reads 0 energy. ⇒ hypothesis is **compute overrun, NOT fronthaul-bandwidth**.

**How the plan CLOSES #9 (killer controls):** **H1(106×4 chanmod OFF) vs L5(106×4 ON)** at identical byte-load ⇒ isolates FIR-compute from byte-load. **A(106×1)/B(52×2)/C(24×4)** all at measured ~620 Mbps ⇒ exonerates FH-load if outcomes differ. **N=5 → k/5** ⇒ flaky (1–4/5) vs hard (0/5). **Standalone `perform_channel_modelling` bench** (15360/30720/61440 samples × nb_tx 1..4 vs `0.5ms/ts` budget) ⇒ samples-vs-nb_tx separation, zero perturbation. **Fixes per cause:** compute → lower `ts` 0.25→0.125, pin/parallelize the FIR actors, or batch; bandwidth-attach → confirm FRAGMENT=16/len_coreset compiled.

**NEXT:** bring up → run G0 24×1 gate (`TS=0.25 STACK_TRIES=6 bash fh_sweep_vrtsim.sh "24"`). Green → run the matrix top→bottom (`WIDEBW_4X4_SWEEP_PLAN.md` §3). Red on all tries → `run_rfsim_clean.sh` discriminator → cold power-cycle (warm reboot may not clear NIC/VEB). See plan §0/§1.

> ## ⚠️ CORRECTION (rev 2) — read first
> The rev-1 claim **"chanmod breaks at wide BW, independent of antenna count, fails even at 1×1"** is **RETRACTED / INVALID.** It rested on a forced-`chanmod`-on-1×1 test that is a **broken/unsupported config** (the control **24:1+chanmod also failed** at narrow BW), and the follow-up runs were further confounded by (a) a `VRTSIM_IQ_DEBUG` build that **perturbs the timing-sensitive cold-start** (computes `vrtsim_iq_stats` every slot even when logs are suppressed → breaks SSB sync) and (b) **config contamination** + (c) an **environment regression** (see Env section). 
> **What still stands:** the FH-load-vs-UL sweep + the *existence* of a wide-BW cliff (original clean sweep). **What is NOT cleanly isolated:** whether the cliff is BW, total FH load, or cold-start reliability — #9 is **reopened**. Treat the rev-1 "isolation table" below as **unverified**.

---

## ⚠️ 2026-06-07 (rev 3) — BOX WEDGED: zero-DL since 16:22, single-ant sweep BLOCKED

Resuming the single-antenna FH-load-vs-UL sweep after a reboot. **The box cannot attach a UE** —
UE never syncs to SSB (`synch Failed`, zero DL energy). The sweep (#4 re-run) is fully blocked.

**Timeline (decisive):** last good attach **16:22** (rb51 1×1, real `oaitun_ue1 IPv4 10.0.0.21`).
Every run after ~16:59 fails — through ~13 pre-reboot attempts, the 19:44 reboot, an i40e
driver reload, and ~30 of my attempts. So the wedge **predates the reboot** (the afternoon
51×4 chanmod + libvrtsim-rebuild + i40e-patch experiments broke it) and **survives reboot + driver reload**.

**Ruled OUT (with evidence):** environment/5GC/VF-MAC-VLAN (all correct); configs (clean, match
backups, iq9/compMeth=1 DU=RU); `libvrtsim.so` (swapped clean 18:54 build; vrtsim.c is git-clean =
identical source to the working run); i40e driver **version** (live=stock, same as 16:22); i40e
**VEB/SR-IOV state** (full rmmod/modprobe + prepare_network — no change); FH **timescale** (0.25
applied both sides); **FH real-time race** (red herring — the 16:22 *working* run also had ~499 race
lines and synced fine).

**REAL harness bug found + fixed:** non-RT dilation needs DU and RU to share **`XRAN_TIME_EPOCH`**
(else dilated clocks diverge → slot/frame mismatch). My harness defaulted epoch=0; the 16:22 run used
a shared `epoch_s=1780874556`. Fix in `fh_sweep_vrtsim.sh`: compute `EPOCH=$(date +%s)` per stack and
pass to both run_ru.sh + run_du.sh. **Verified: FH race 6570 → 0.** (But UE still doesn't sync — epoch
was necessary, not sufficient.)

**Remaining root-cause (leading hypothesis):** all on-disk artifacts (binaries, configs, vrtsim source,
driver) are **identical to the 16:22 working state**, yet **DL U-plane does not flow DU→RU** while
**UL U-plane RU→DU works at 100%** (`UL sym present 5000/5000`). A reboot- and driver-reload-surviving,
**directional** DL failure points to **X710 NIC hardware/firmware/VEB state** (stuck forwarding entry for
the RU U-plane MAC `00:11:22:33:64:66` on VLAN 3) that only a **cold power cycle** clears. Alt hypothesis:
a lost uncommitted vrtsim/FH source change that produced the working pre-16:46 `libvrtsim.so` (overwritten
16:46; no git stash) — but vrtsim.c is git-clean, which argues against it.

**rfsim DISCRIMINATOR (2026-06-07, ran it):** `run_rfsim_clean.sh` (pure-software channel, NO NIC) →
**full attach on try 1** (UE 10.0.0.2, RRC+reg+PDU, ping 3/3). So CN + UE + RACH + DL-generation all
work; only the **X710 NIC fronthaul path** fails. NIC confirmed as the culprit. (Caveat: rfsim uses the
oai_rfsim_clean gNB build, not the vrtsim DU build — but the vrtsim DU binary/config are identical to the
16:22 working state, so the weight of evidence is the NIC.)

**NEXT STEP:** cold power-cycle the host (full power-off, not warm reboot) → `prepare_network.sh` →
restart 5GC (`docker start` the oai-cn5g containers) → `bash fh_sweep_vrtsim.sh "24"`. If 24×1 attaches,
run `"24 51 106"`. If it STILL fails after a cold cycle, the NIC is exonerated → bisect the DU DL-TX path
(rfsim sanity check isolates stack-vs-FH). Harness + epoch fix are ready in `fh_sweep_vrtsim.sh` (in-repo,
survives reboot). Clean libvrtsim already swapped into `build/`.

---

## TARGET (goal)

OAI 5G NR **O-RAN 7.2 split** lab in `/home/jesse/oran_lab/`: DU + O-RU + UE on one host,
**real DPDK/SR-IOV fronthaul via xran**, **vrtsim** shared-memory time-domain IQ air channel,
OAI 5GC in docker. Run the whole split **slower-than-real-time** (non-RT dilation) so L1 compute fits.

Recent objective (the `/loop`): produce **FH load (sweep PRB / antennas) vs UL throughput**, with
FH latency / jitter / loss + UL jitter, **WITHOUT injecting any assumption model** (unlike the rfsim
thread). Goal = *see how real FH throughput degrades under load, and how that degradation hits UL.*
Sub-goals raised along the way: multi-UE, **4×4 MIMO**, investigate the inactive-UE clamp.

---

## PROBLEMS (open/closed)

### CLOSED
1. **Non-real-time FH** — make xran's timer/deadline subsystem timescale-aware so the full split runs
   under dilation. ✅ `XRAN_TIMESCALE` env + inline-cb path. Commit `428753a` (branch `xran-timescale`),
   file `fhi_lib/lib/src/xran_cb_proc.c` (`xran_arm_or_run_inline()`, all 6 arm sites). iperf = wall ÷ timescale.
2. **Wide-BW attach fails (RAR/CORESET overlap)** — 51/106 PRB couldn't complete RA. Root = `len_coreset`
   computed too small at wide BWP → RAR/CORESET0 overlap. ✅ Fix `len_coreset = 2` unconditionally,
   `nr_radio_config.c:1033`, commit `b46a6ad189` (branch `compression-plus-timing-fix`). 51 + 106 PRB now attach.
3. **`sec_desc` section-descriptor overflow at wide BW** — `XRAN_MAX_FRAGMENT(7)` too small. ✅ Raised to 16,
   `xran_fh_o_du.h:144`, commit `28877f6`. Required rebuilding BOTH libxran AND oran_fhlib_5g. ABI-safe
   (verified 24:1 still attaches clean @ 7.12 Mbps).
4. **FH-load (PRB) vs UL throughput** — DELIVERED. `logs/fhsweep/fh_load_vs_ul.png` +
   `logs/fhsweep/fh_vs_ul_consolidated.csv`. See data table below.
5. **Cliff root cause** — PARTIALLY narrowed (see ⚠️ correction): it's **software (chanmod), NOT VF, NOT
   CPU, NOT a real mbuf bug, NOT PRACH detection.** But the rev-1 sharpening ("wide-BW only, antenna-
   independent, fails at 1×1") is **RETRACTED** — that came from an invalid forced-1×1-chanmod config.
   Reopened as #9. What's solid: chanmod-MIMO configs cliff at higher load; the discriminator (BW vs load
   vs cold-start reliability) is **not cleanly isolated**.
6. **mbuf exhaustion** (`Assertion mbuf!=NULL … xran_oru_send_pusch`, `oaioran_ru.c:1421`) — REFUTED as a
   stable cause; it was a **debug artifact** (my `VRTSIM_IQ_DEBUG` printfs slowed the RU read → FH
   backpressure → pool drain). Clean run (debug reverted) = **0 crashes**.
7. **chanmod write TOO_LATE / drops the PRACH** — REFUTED. The chanmod write succeeds (`ret=0`,
   `nonzero=4096/4096`, positive budget). The energy is written; the RU just doesn't read it.
8. **Ring-buffer wrap / TOO_EARLY** — REFUTED. `CIRCULAR_BUFFER_SIZE = 30720·14·20 = 8.6M samples`
   (~280 ms @ 30.72 Msps); the ~1 ms-ahead write fits trivially.

### OPEN
9. **Why chanmod-MIMO cliffs at higher BW/load (→ unblock 4×4 / wide-BW MIMO).** REOPENED. _→ rev-4 top block + `WIDEBW_4X4_SWEEP_PLAN.md` §6 have the full mechanism + isolation design._ Solid facts:
   `CHAN=AWGN channel_length=1` (single-tap, BW-independent logic); 51:1 wide-BW works *without* chanmod
   (so position/channel math + VFs are fine at wide BW); among real MIMO configs 24:2/24:4 attach (marginally)
   while 51:2/51:4 don't. **Discriminator NOT isolated** (BW vs total FH load vs cold-start reliability all
   covary). ⚠️ **Methodology trap:** every in-process instrument I tried *perturbs* the timing-sensitive
   cold-start and changes the outcome (the `VRTSIM_IQ_DEBUG` build broke even 24:1 baseline sync). A
   non-perturbing approach is needed — e.g. snapshot/dump the `/dev/shm` channel buffer offline, or unit-test
   `perform_channel_modelling` standalone, rather than live printf. Code refs unchanged (vrtsim.c
   `vrtsim_write_with_chanmod`:991, `perform_channel_modelling`:789; shm tx:145/rx:181).
10. **4×4 / wide-BW MIMO unusable** — 24-PRB MIMO attaches (marginal); 51/106-PRB MIMO does not. Blocked by #9.
11. **Inactive-UE clamp** (earlier sub-goal) — partial; revisit. UL stays scheduler-bound (1 UL slot/period
    cadence; `min_grant_prb` clamp). Not blocking the FH-load deliverable.

### ENVIRONMENT / METHODOLOGY (hard-won, 2026-06-07 — read before more runs)
- **RU hugepage LEAK:** each run leaks ~**8192 hugepages (16 GB)** as `/dev/hugepages/rumap_*`. `rm -f
  /dev/hugepages/*` does **NOT** clear them (silently fails); **`sudo find /dev/hugepages/ -type f -delete`
  does.** Accumulation over a few runs → fragmentation/exhaustion → DPDK memory starves → **DU FH real-time
  race** (`Received Time doesn't correspond` / `TTI processing delay`, thousands of lines) → even 24:1
  baseline `synch Failed`. ALWAYS `find -delete` hugepages between runs.
- **`VRTSIM_IQ_DEBUG` build is too perturbing** — its per-slot `vrtsim_iq_stats()` runs even when `LOG_I(HW)`
  is suppressed by `hw_log_level="warn"`; it jitters the RU loop and breaks SSB sync. Do **not** use it for
  cold-start/timing tests. (Also why the rev-1 "mbuf crash" was a phantom.)
- **Config contamination trap:** `timeout`-killed `fh_sweep.sh` runs skip `restore()`, leaving `nb_tx=2` +
  `@include channelmod_sweep.conf` in the base configs → next run's baseline is poisoned. Restore from
  `du_test.conf.preNoBFPprach_bak` / `ru_test.conf.preNoBFPprach_bak` / `ue_test.conf.good_bak` (verified
  clean: nb_tx=1, no chanmod include) and `rm channelmod_sweep.conf` before trusting any baseline.
- **Box health checklist before a run:** hugefree≈11375 (`find -delete`), 1-min load < ~1.5 (let the box
  settle after a barrage), VF 06:02.0-3 on `uio_pci_generic`, no stale `nr-*` procs, CPU cores reach ~4.5 GHz
  under load (cores are fine — 5 GHz max, ~16 °C, not throttled). If the DU still FH-races after all that, the
  box state is wedged → **reboot** (clears DPDK/SR-IOV/cgroup state) before continuing.

---

## TEST RESULTS (proof)

### FH-load-vs-UL sweep (`fh_vs_ul_consolidated.csv`, ts=0.25 unless noted, AWGN, ploss=0)

| FH load (Mbps) | config | UL (Mbps, sim) | attached | note |
|---|---|---|---|---|
| 150.8 | 24PRB ×1 | 7.20 | ✅ | clean |
| 301.5 | 24PRB ×2 | 7.20 | ✅ | 2ant = 2× FH load; **UL flat** |
| 310.4 | 51PRB ×1 | 15.16 | ✅ | min_grant=51 → UL 2× |
| 603.0 | 24PRB ×4 | 6.44 | ✅ | marginal (4ant, rank-1, lucky attach) |
| 636.0 | 106PRB ×1 | 7.36 | ✅ | ts=0.50; marginal (attached try 5/6) |
| 620.0 | 51PRB ×2 | 0 | ❌ | **CLIFF onset** — chanmod overrun + xran_queue crash |
| 1240 | 51PRB ×4 | 0 | ❌ | CLIFF — attach fails |
| 2540 | 106PRB ×4 | 0 | ❌ | CLIFF — PBCH sync + sec_desc storm |

**Read:** below ~640 Mbps FH is **over-provisioned** and UL is **scheduler-bound** (flat 7–15 Mbps);
then a **hard cliff** to 0. No graceful FH-degradation curve → *this is why the rfsim thread injected a loss model.*

### Chanmod isolation (the #5/#9 proof), ts=0.25, AWGN, ploss=0

| config | chanmod | RU rxdata `slot_energy` | attach |
|---|---|---|---|
| 51 PRB **1×1** | **OFF** | energy present | ✅ |
| 51 PRB **1×1** | **ON** (forced) | **0** — all 11,377 `[ORU PRACH RAW]` lines | ❌ |
| 51 PRB 4×4 | ON | 0 — all 51,174 lines | ❌ |
| 24 PRB 4×4 | ON | energy present | ✅ |

Conclusion: chanmod-ON + wide-BW fails **even at one antenna** ⇒ chanmod×bandwidth, NOT the 4-aarx scaling,
NOT VF, NOT CPU (`chanmod_slow=0`, dilation gives 4× wall-clock headroom).

---

## REUSABLE ASSETS

**Harnesses (in `/tmp`, recreate if cleared):**
- `fh_sweep.sh` — FH-load sweep. `POINTS="PRB:NB_ANT"`, dilation + chanmod(NB>1), `min_grant_prb=PRB`.
  Output dir = `logs/fhsweep/<TIMESTAMP>/p<PRB>_a<NB>/`. **Gotchas:** dirs named by timestamp not label;
  don't kill mid-run + relaunch (it snapshots the corrupted config as baseline).
- `fh_chanmod1.sh` — the #5 isolation: `sed 's/if [ "$NB" != "1" ]; then/if true; then/'` forces chanmod
  on a 1×1 config (antennas stay 1×1) to separate chanmod from antenna count.
- `mimo4x4.sh` — 4×4 MIMO under dilation.

**Config backups:** `du_test.conf.preNoBFPprach_bak`, `ru_test.conf.preNoBFPprach_bak` (clean 24-PRB nb=1
min_grant=24); `ue_test.conf.good_bak`. ⚠️ Do NOT `grep -v file > file` — the RTK wrapper corrupts it; use cp/sed.

**Box reset (recurring instability — VFs revert to iavf, hugepages fragment, stale procs):**
`sudo pkill -9 -x nr-softmodem|nr-oru|nr-uesoftmodem` → `sudo rm -f /dev/hugepages/*` →
`sudo bash prepare_network.sh` (rebinds VF 06:02.0-3 to uio_pci_generic). Verify VFs on uio_pci_generic before any run.

**Key code (chanmod path), in `oaicicd/test_dir/openairinterface5g`:**
- `radio/vrtsim/vrtsim.c`: `vrtsim_write_with_chanmod`:991 (batch_size=4096, async per-aarx FIFO),
  `perform_channel_modelling`:789 (FIR), `vrtsim_write_internal`:710.
- `common/utils/shm_iq_channel/shm_td_iq_channel.c`: `tx`:145, `rx`:181 (**destructive** — memset 0 after read),
  `CIRCULAR_BUFFER_SIZE`:36.
- FH-tree diagnostic prints live **uncommitted** in `executables/nr-oru.c`, `openair1/SCHED_NR/nr_prach_procedures.c`,
  `radio/fhi_72/oaioran.c`, `radio/fhi_72/oaioran_ru.c` (`[ORU PRACH RAW]`, `[gNB PRACH RX]`). vrtsim.c debug
  reverted + rebuilt clean. **Clean these up if winding down.**

---

## NEXT STEP (to resume #9)

Re-enable a *targeted* dual-side log: in the chanmod write (`vrtsim_write_internal`, role==CLIENT) print
`timestamp, global_aarx, nsamps`; in the RU rx (`shm_td_iq_channel_rx`, SERVER) print `timestamp, antenna, first_nonzero`.
Run 51:1 + chanmod. Compare the chanmod-write timestamps/antenna vs the RU-read timestamps/antenna for the PRACH
slot — find whether they mismatch (position) or the read precedes the write (async race). That pins the exact line.
Keep instrumentation minimal (heavy printf perturbs timing — that's what faked the mbuf crash).
