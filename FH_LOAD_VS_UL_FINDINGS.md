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

## rev-20 (2026-07-04): ASYMMETRIC-ANTENNA DL WALL — chanmod refuted, root cause = neAxc=max
**[CLOSED] Option A (chanmod) does NOT fix asymmetric-antenna DL.** Ran chanmod 1TX/4RX iq9@273 clean AWGN: `fh_rx(DL)=0.000`, UE 60x "synch Failed", no attach. Chanmod is the WRONG LAYER — it shapes RU->UE radio samples, but the failure is the DU->RU **xran fronthaul carrying 0 DL bytes**. One hop too early for a channel model to matter.
**[OPEN] Root cause: `neAxc = RTE_MAX(tx_num_channels, rx_num_channels)` (oran-config.c:989) zeroes DL FH when nb_tx<nb_rx.** DU log `neAxc 4 neAxcUl 0 NB_TX 1 NB_RX 4`. Discriminator table: sym 1x1 (neAxc1=nb_tx) DL=1133 ✅5/5; asym 2TX/4RX (neAxc4>nb_tx2) DL=0.000 ❌; asym 1TX/4RX+chanmod (neAxc4>nb_tx1) DL=0.000 ❌. UL fine either way (fh_tx=1968=4RX). The single DL eAxC (eAxC0) sent by the nb_tx loop produces 0 RX at the RU when the xran TX config is sized for neAxc=4 — not a "missing eAxC 1-3" problem, eAxC0 itself dies.
**Both multi-antenna UL-FH routes walled in vrtsim:** asymmetric (few TX/many RX) → neAxc=max zeroes DL FH (this xran bug); symmetric NxN → DL FH flows but identical-channel passthrough cancels the precoded TX (rank-1), and decorrelating via TDL chanmod breaks initial sync (known vrtsim multi-ant wall).
**Decision: antenna excursion STOPPED — goals already met.** ">5Gbps FH" met via IQ-width (iq16@273 FH~2.75Gbps sim; dilation loaded ~9.9Gbps sim 0-late). "UL at FH limit" met+proven (UL flat ~60-70 sim across FH 1.6->5.5Gbps, decoupled). More antennas = realism only; requires real xran patch (decouple DL eAxC=nb_tx from UL eAxC=nb_rx, Cat-B neAxcUl style) — deep, doesn't change the UL-vs-FH conclusion.

## rev-21 (2026-07-04): MASSIVE-MIMO ASYMMETRIC — RU crash root-caused + FIXED; sync+SIB1 unblocked
**[CLOSED] FH direction was misread in rev-20.** [FH LOAD] is emitted by the o-du (oaioran.c:893): rx=DU-receives=UL, tx=DU-transmits=DL. So `rx=0.000 tx=1968` = DL FH WORKS (1968 Mbps, 70144 pps), UL=0 is just the consequence of no attach (no UE UL). The DL fronthaul was never broken.
**[CLOSED] RU segfault with nb_rx=4 (ALL asymmetric massive-MIMO configs) — ROOT-CAUSED + FIXED.** dmesg: `oru_sync_thread segfault at 8 in liboran_fhlib_5g.so[d990]` = addr2line -> xran_oru_tx_read_slot @ oaioran_ru.c:542 (`rte_pktmbuf_free(uplane_data[i]->mbuf_to_free)`, mov 0x8(%rbx)). MECHANISM: DL U-plane validation (oaioran_ru.c:689) bounds Ant_ID by neAxc=max(nb_tx,nb_rx)=4, but the DL consumer writes `tx_data_sym[aatx]` sized [nb_tx]=1. A DL pkt with aatx in [nb_tx,nb_rx) (the DU/xran emits empty U-plane on all neAxc eAxC) -> OOB stack write -> smashes uplane_data[] pointer array -> NULL-deref at the free ~30s in. FIX: bound-check `aatx>=nb_tx` in the DL consumer loop (oaioran_ru.c ~472), drop the spurious pkt (no DL content there; DU only fills aatx 0..nb_tx-1). Rebuilt liboran_fhlib_5g.so (.bak_pre_aatxguard; source .bak_aatxguard). CONFIRMED: guard fires `drop DL pkt aatx=1/2/3 out of [0,nb_tx=1)`, RU stable entire run (was 30s-death). Symmetric unaffected (aatx<nb_tx always holds when neAxc=nb_tx).
**[CLOSED] Regression: symmetric 1x1 no-chanmod still attaches** status=ok fh_total=1625.9 ul=15.4 (iperf; LCID4 ~60 sim). No regression from the DL-path guard.
**[OPEN] Asymmetric 1TX/4RX: UE stalls after SIB1, before RACH.** With the crash fixed, UE now: syncs (unstable, ~23 synch-Failed then 1-2 success), decodes SIB1 (FIRST TIME for asymmetric), configures TDD — then exits cleanly (no timeout/assert/segfault) before sending PRACH Msg1. DU sees PRACH energy 0.0 dB, UL sym present 0/5000 (UL never exercised because UE never RACHes). NOT a timing/deadline issue: ts=0.125 gives identical result (sync+SIB1 then die). Root = intermittent RU->UE DL delivery with the asymmetric vrtsim channel (server reads 4 UL streams/slot + writes 1 DL stream; DL SSB arrives marginally -> unstable sync -> can't sustain DL through to RACH). Deeper vrtsim asymmetric-channel issue; next layer. Datum: DL FH 1968 flows fine, so DU->RU is not the limit; RU->UE (vrtsim) is.
**Net: the crash fix is the foundation — asymmetric massive-MIMO no longer crashes the RU. Path forward is the post-SIB1 vrtsim DL-delivery.** Canonical: rev-21.

## rev-22 (2026-07-04): MASSIVE-MIMO UL — correct config found, UL FH loaded 4.5 Gbps, final blocker = UL PRACH not reaching DU at 4 RX
**[CLOSED] The rev-21 asymmetric stall was a WRONG-CONFIG artifact, not a vrtsim DL bug.** Diffing UE logs 1x1(attach) vs asym(stall): sync instability is IDENTICAL (both ~14 synch-Failed then 1 success — NOT 4RX-specific). Divergence is one step after SIB1: 1x1 -> `N_TA_offset 0->1600` -> `Initialization of 4-Step CBRA` -> PRACH; the asym UE stops at "Configured TDD patterns". ROOT: sweep hardwired `UE_NB_ANT_TX=gNB_RX` (sweep_iq_width.sh ~140), so gNB 4RX forced a **4-TX UE**, and the UE's 4-TX UL setup stalls at RA kickoff. But 4-TX UE is WRONG for massive MIMO anyway.
**[FIX] Decoupled UE antenna counts from the gNB (sweep_iq_width.sh): `export UE_NB_ANT_TX="${UE_NB_ANT_TX:-${nbrx}}"` etc.** Correct massive-MIMO UL = SIMPLE UE (1 TX) into MANY-RX gNB. Config: `UE_NB_ANT_TX=1 UE_NB_ANT_RX=1 NB_ANT_TX=1 NB_ANT_RX=4`. DL is then byte-identical to the proven 1x1 (UE rx=1 reads 1 DL stream; server writes 1 DL stream from gNB TX0). vrtsim: single-UE read grabs UL stream0 and copies to all 4 gNB RX (ideal receive-combining, +6 dB array gain, no spatial diversity).
**[WORKS] UE 1x1 + gNB 1TX/4RX: FULL RA reached — sync, SIB1x2, `4-Step CBRA`, PRACH TX x100.** No stall, no crash (UE alive whole run). And **UL FH LOADED: rx=4535 Mbps (4 UL eAxC, 194560 pps) vs tx=1968 DL** = the massive-MIMO UL fronthaul load is achieved (~4.5 Gbps UL, 6.5 Gbps total). Sync is flaky cold-start (1 run 122 fails/never synced; re-run synced) = the known attach lottery, not a hard fail.
**[OPEN — FINAL BLOCKER] UL PRACH content does not reach the DU at 4 RX.** DU sees PRACH `energy 0.0 dB` on every occasion; nonzero-energy count 0/45 (vs 7 for the working 1x1). So UL FH is loaded but carries ZEROS for the PRACH. UE TXs PRACH 100x, all get "RAR reception failed", then DL degrades (all-0 pdu / PBCH error / SIB1 NACK) and RA gives up. The UE-side UL write (1 stream) is identical to 1x1, and the server UL read (stream0) is identical to 1x1 — the delta is the RU copy-to-4-RX + 4-eAxC PRACH extract/send path (oaioran_ru.c PRACH send ~1095-1170, known-fragile per rev-6/rev-9). Next dig: why the RU's 4-aarx UL/PRACH U-plane is zeros (read-timing shifted by 4x eAxC send work, or the copy/extract path). Massive-MIMO UL FH-LOAD is proven; UL DATA delivery at 4 RX is the last mile.
**Net progress: crash fixed (rev-21) + correct mMIMO config (UE 1x1/gNB 4RX) + UL FH 4.5 Gbps loaded. One blocker left: UL PRACH/PUSCH content at 4 RX.** Canonical: rev-22.

## rev-23 (2026-07-04): UL U-PLANE ZEROS ROOT-CAUSED + PARTIAL FIX (UL read advance decoupled)
**[ROOT CAUSE — PROVEN via IQ instrumentation]** massive-MIMO UL PRACH=0.0 dB at DU is a vrtsim UL READ-ALIGNMENT bug, NOT a send/extract bug. Compiled VRTSIM_IQ_DEBUG: **UE WRITES nonzero PRACH fine** (677 nonzero [VRTSIM UL TX] at slot-in-frame 19, nonzero=4381/61440, energy 3.5M). RU reads ZEROS ([ORU PRACH RAW] raw_nz=0). CODE: vrtsim_read server does `read_sample = last_received + tx_sample_advance` but returns `*ptimestamp = last_received` — reads ~1 slot AHEAD of the label. tx_sample_advance=65536 ≈ 1 slot (61440). The DL WRITE-ahead was wrongly reused as the UL READ-ahead. Marginal for 1x1 (attaches on 2nd PRACH); consistently fatal at 4RX.
**[FIX — implemented, PARTIAL]** Added env-tunable `ul_read_advance` (VRTSIM_UL_READ_ADVANCE, default=tx_sample_advance=legacy) used only in the UL read; vrtsim.c + run_ru.sh (env passthrough). Rebuilt libvrtsim (.bak_pre_iqdebug, source .bak_ulreadadvance). With **VRTSIM_UL_READ_ADVANCE=0**: `UL sym present 0/5000 -> 5000/5000 (100%)` and RU PRACH reads 0 -> 26 nonzero. **The general UL U-plane now DELIVERS.** BUT attach still fails: DU PRACH energy still 0.0 dB (my earlier "nonzero=1,2,3" was a GREP ARTIFACT — interleaved [HW] logs split "energy 0.0 dB"). 
**[OPEN — residual] PRACH-specific frame-boundary alignment.** UE places PRACH at write-buffer offset ~57056 (symbol ~13, slot-END) of slot 19, but nr-oru extracts at symbol 0 (slot-START). advance=0 aligned the PUSCH UL slots (100% sym) but not the PRACH at the last slot of the frame. This is the nr-oru PRACH extraction / get_timestamp-sync alignment (rev-7 root target). raw_nz 26/10025 = PRACH only intermittently in the read window. NEXT: shift PRACH extraction to the UE's actual PRACH offset, or fix the slot-19 (frame-boundary) read alignment; also verify VRTSIM_UL_READ_ADVANCE=0 on the 1x1 baseline before making it default.
**Progress this session: crash fixed (rev-21) + correct mMIMO config (rev-22) + UL FH 4.5 Gbps + UL U-plane delivery 0->100% (rev-23). Attach blocked only by the PRACH frame-boundary alignment residual.** Canonical: rev-23.

## rev-24 (2026-07-04): PRACH EXTRACTION SHIFT — DU PRACH detection restored 0.0->48 dB (attach residual = RAR handshake)
**[FIXED] PRACH now reaches+detected at DU.** rev-23 proved UE writes PRACH at slot-buffer offset 57056 (= symbol 13, slot-END; 61440-57056=4384=1 OFDM symbol `sum`), while nr-oru extracts at symbol 0 (sample_offset_slot=0 for prachStartSymbol==0, nr_prach.c:141). PUSCH aligns at UL_READ_ADVANCE=0 but PRACH needs a DIFFERENT within-slot offset -> not a global read-advance fix. Added env ORU_PRACH_SAMPLE_SHIFT to nr-oru receive_prach (passes N_TA_offset - shift, moving the extraction base later; nr-oru.c ~521, run_ru.sh passthrough; rebuilt nr-oru .bak_prachshift). ORU_PRACH_SAMPLE_SHIFT=56720 (57056-Ncp1936-... aligns DFT to PRACH; dftlen4096 fits before slot end, no frame-wrap): **DU PRACH energy 0.0 dB -> 48.0 dB, RU raw_nz 0 -> 30+**. The full UL knob stack for mMIMO: VRTSIM_UL_READ_ADVANCE=0 (PUSCH/UL delivery 0->100%) + ORU_PRACH_SAMPLE_SHIFT=56720 (PRACH detection 0->48dB).
**[OPEN — attach residual] RA handshake past Msg1.** DU detects PRACH but (a) preamble index SCATTERED (detects 6-9 & 60-63, not the UE's sent index) at a saturated constant 48.0 dB — shift is close but not sample-exact, AND the 4 identical vrtsim RX copies coherently add -> correlation saturates/smears across cyclic shifts; (b) UE "RAR reception failed" (RAPID mismatch from wrong detected preamble) -> no Msg3 -> DU "MSG3 ULSCH with no signal" -> "RA failed at WAIT_Msg3". NEXT: sample-accurate PRACH offset (sweep ORU_PRACH_SAMPLE_SHIFT ±cyclic-shift to get a SINGLE correct preamble index = UE's sent index), and/or fix the 4-RX coherent-copy saturation (scale combine by 1/sqrt(nrx) or use 1 RX for PRACH). Then RAR RAPID matches -> Msg3 -> attach.
**Progress: crash fix + mMIMO config + UL FH 4.5Gbps + UL delivery 0->100% + PRACH detection 0->48dB. Attach residual = sample-exact PRACH offset + RAR handshake.** Canonical: rev-24.

## rev-25 (2026-07-04): UL de-saturation infra built (per-antenna noise); attach blocked by PRACH TIMING JITTER + RAR
**[BUILT] Per-antenna independent UL noise** (VRTSIM_UL_NOISE_STD, fast inline xorshift, applied at RU server read after copy; vrtsim.c .bak_ulnoise, run_ru.sh passthrough). Rationale: no-chanmod passthrough has ZERO noise -> gNB I0~0 -> PRACH detection saturates at constant 48 dB (scale-invariant, so attenuation can't help — must raise I0). INDEPENDENT per-antenna (distinct xorshift seeds) so the 4-RX coherent combine yields real array gain (signal +12dB coherent, noise +6dB incoherent = +6dB SNR massive-MIMO gain), per user: keep the coherent-copy gain, lower the input SNR instead. Perf: 3x rand_r/sample slowed RU to death (UL sym 754/5000, RU died) -> switched to 1 xorshift/sample uniform (RU stable). Use ts=0.5 for extra RU budget (offsets are sample-based, ts-invariant).
**De-saturation confirmed in principle** but level not dialed: noise=50 buried noise-false-alarms to 0.0dB; noise=10 with a REAL synced UE = real PRACH still 48dB (too weak; real PRACH strong due to correlation processing gain ~36dB, so need noise ~200-300 to hit ~20dB detection — untested, needs a good-sync launch). The "24dB" seen once was a NO-SYNC run = pure noise false-alarm, not real.
**[OPEN — real blocker, deeper than a constant offset] PRACH timing JITTERS per attempt.** DU RAPROC `delay` field spread 0..61 samples across attempts (delay 0 ×7, 51 ×7, 17 ×5, 40, 61, ...). ORU_PRACH_SAMPLE_SHIFT=56720 gets PRACH into the window (48dB) but the residual timing is NOT constant -> maps to WRONG cyclic-shift/preamble on many attempts -> DU sends RAR with wrong RAPID -> UE "RAR reception failed". A single fixed shift CANNOT fix a per-attempt jitter. Even the delay-0/correct detections fail RAR -> SECOND coupled fault: likely RA-RNTI mismatch from DU/UE frame drift (UE frame 339 vs RU 735), or RAR PDSCH landing in a marginal DL moment. Plus cold-start SYNC is flaky (2 of ~4 launches never synced) making each iteration expensive.
**Status: massive-MIMO UL infra all built (crash fix, config, UL FH 4.5Gbps, UL read advance, PRACH shift, per-antenna noise/array-gain). Attach still blocked by the attach-lottery ROOT = sub-slot PRACH timing jitter + RA-RNTI/RAR frame-drift + sync flakiness. These are coupled and need systematic work (fixed-preamble CBRA, controlled sync, delay-driven per-attempt alignment), not a constant knob.** Canonical: rev-25.

## rev-26 (2026-07-04): PRACH DISAMBIGUATED — it's a CONSTANT offset (fixable), NOT jitter/saturation/RAR
**Systematic harness built:** (1) OAI_UE_FIXED_PREAMBLE env forces the UE CBRA preamble (nr_ra_procedures.c config_preamble_index end; rebuilt nr-uesoftmodem .bak_fixpreamble; run_ue.sh passthrough) so detected-vs-sent is directly comparable; (2) prach_probe.sh retries the mMIMO launch until the UE actually syncs+probes PRACH (cold-start sync ~50% flaky), then auto-harvests.
**RESULT (fixpre=0, shift=56720, NO noise, synced try 1):** UE sent 100x preamble 0 -> **DU detects preamble 40, delay 2, 19.4 dB, CONSISTENTLY (10/10)**. Three conclusions that overturn rev-25:
  1. NOT jitter — the rev-25 "delay spread 0-61" was just RANDOM preambles each having their own cyclic-shift delay. Fixed preamble = rock-constant detection (40, delay 2). A constant offset IS fixable with a precise shift.
  2. NOT saturation — single clean 19.4 dB detection, no noise needed. The earlier "48 dB" was random-preamble aliasing. (Per-antenna noise infra from rev-25 stays available but is NOT needed for detection.)
  3. NOT the RAR (yet) — the PRACH is simply decoded as the WRONG preamble (40 vs 0) -> RAR carries wrong RAPID -> UE rejects. Fix the offset and RAR RAPID should match.
**Reduced problem:** extraction offset maps sent-0 -> detected-40. Detected-high => window too EARLY => INCREASE ORU_PRACH_SAMPLE_SHIFT. Data point 1: shift=56720 -> detected 40. Measuring slope (samples per cyclic-shift) with shift=59280 (+2560, est ~64 samp/preamble) to solve for detected=0. Then detected preamble should = sent 0 at delay ~0 -> RAR RAPID match -> Msg3 -> attach. Canonical: rev-26.

## rev-27 (2026-07-04): PRACH +40 offset = PRACH at SYMBOL 13 vs symbol-0 reference (sequence-domain, NOT window-fixable)
Two-point shift sweep (fixed preamble 0): shift 56720 -> detected preamble 40 delay 2; shift 59280 -> preamble 42 delay 15. Slope only +2 preambles / +2560 samples => window shift CANNOT reach detected=0 (would need shift ~5520, off the physical PRACH). Delay SMALL (2) at 56720 => window already near-exact on ENERGY. So the +40 is a SEQUENCE/REFERENCE-domain offset, not fine-timing.
**ROOT:** UE writes PRACH first-nonzero at slot-buffer offset 57056 = EXACTLY symbol-13 start (4448 + 12*4384; ofdm_symbol_size=4096, CP=288, CP0=352, 14 sym/slot). RU/DU PRACH reference = symbol 0 ("PRACH start symbol 0 lastsymbol 11"). PRACH occasion is in the mixed/last slot's UL symbols (TDD 2DL/4UL; mixed = 6 DL sym + 4 UL sym) so the UE (correctly) puts it at the END; the RU/DU extraction reference (sample_offset_slot=0 for prachStartSymbol==0, nr_prach.c:141) sits at the START. The ~13-symbol (~0.93-slot ~57056-samp) gap read against a symbol-0 correlation reference = ~40 cyclic-shift => detected preamble 40. msg1_freq 130 matches, root idx 0, UE -A=0 (none of those).
**Why ORU_PRACH_SAMPLE_SHIFT can't fix it:** it moves the extraction WINDOW (via N_TA_offset) to capture ENERGY, but NOT the cyclic-shift REFERENCE (DFT-bin-0 / prachStartSymbol). Both must move together. Real fix: align DU/RU PRACH START SYMBOL with where the UE actually transmits (symbol 13) -- pass correct prachStartSymbol/sample_offset_slot into rx_nr_prach_ru_internal -- OR make the PRACH occasion a full-UL slot (symbol 0) so UE & DU agree. This is the ~1-slot frame-boundary alignment = attach-lottery ROOT, now pinned to PRACH-start-symbol vs mixed-slot placement.
**Systematic harness delivered its purpose (DIAGNOSIS):** OAI_UE_FIXED_PREAMBLE + prach_probe.sh (retry-until-sync) turned "jittery mystery" into "constant, explained +40 = symbol-13-vs-0". NEXT real fix: set extraction prachStartSymbol to the UE's actual PRACH symbol so window AND reference align -> detected=0 -> RAR RAPID match -> attach. Canonical: rev-27.

## rev-28 (2026-07-04): PRACH +40 is ROOT/FREQUENCY-domain, NOT timing (adversarial workflow overturned rev-27)
Ran a 6-agent workflow (analyze x4 -> synthesize -> ADVERSARIAL verify). The verifier REFUTED both rev-27's "symbol-13 timing" and the synthesis's "revert shift + fix vrtsim alignment". KEY correction: **zeroCorrelationZoneConfig=0 => N_CS=0 => the 64 preambles are 64 DISTINCT ZC ROOTS (preamble index == logical root), NOT cyclic shifts of one root.** A TIME offset is a linear phase ramp across PRACH subcarriers -> it CANNOT turn root 0 into a clean root-40 peak. The measured detection (clean single 19.4 dB peak at preamble 40, delay 2, cross-root floor ~21 dB down) = GENUINE root-40 correlation energy => a ROOT/FREQUENCY-domain discrepancy. This explains why the window-shift knob (ORU_PRACH_SAMPLE_SHIFT) could never converge (slope +2 preambles / +2560 samples; extrapolating to 0 lands in an empty part of the buffer). The whole symbol-13/timing chase (rev-23..27) was chasing the wrong domain. DO NOT ship shift=0 (points at empty slot start -> detects nothing).
CONFIG FACTS reconciled: du prach_RootSequenceIndex=1 (config) BUT oran-config.c:791 HARDCODES nPrachRootSeqIdx=0 ("should be saved from config file; not used in xran"); RU log nPrachRootSeqIdx 0; UE first_nonzero_root_idx 0; freq: config msg1_FrequencyStart=0 -> runtime 130 on BOTH UE and RU. So UE & RU roughly agree at runtime -- a pure root-index slip is +/-1, NOT +40. The +40 must come from a FREQUENCY/subcarrier extraction offset (ZC time-freq duality: a k-subcarrier offset aliases root u -> root u+40 for this L_RA=139/N_CS=0 config) OR the correlator root enumeration. Second focused workflow (wf_ed841d63) running to quantitatively pin which k / offset yields exactly +40 and the fix + a cheap empirical prediction. Tooling: fixed-preamble knob (OAI_UE_FIXED_PREAMBLE) + prach_probe.sh (retry-until-sync) are the diagnosis harness. Canonical: rev-28.

## rev-29 (2026-07-04): BFP-on-PRACH REFUTED as the +40 cause (empirical, identical result)
Second workflow (wf_ed841d63) adversarial verifier: root-index config mismatch CANNOT be the cause (both UE-SIB1 and DU-L1 read the same rach_ConfigCommon l139; a static mismatch would be perfectly window-INVARIANT, but the data drifts 40->42 with the window). So the +40 is upstream FH-extraction corruption of the received 139-bin ZC vector; top candidate = BFP compression on PRACH (iq_width_prach=9, compMeth_prach=1). Project history offline-discriminator: rfsim (no FH) attaches, so radio gen/correlate is correct -> FH split is the culprit.
EMPIRICAL TEST: set iq_width_prach=16 + compMeth_prach=0 (BFP OFF) in both du/ru .bak configs, re-ran the fixed-preamble-0 harness. RESULT = IDENTICAL: preamble 40, delay 2, 19.4 dB. => **BFP is byte-transparent here; NOT the cause.** So the corruption is NOT in FH compress/decompress; it's in the BIN EXTRACTION/DFT (RU rx_nr_prach_ru_internal producing prachF, or the g_kbar 139-into-144 mapping, or the DFT grid) OR a genuine root-enumeration offset. g_kbar is symmetric (both sides read ORAN_PRACH_CONFIG_KBAR from config). Reverted BFP to on (baseline).
NEXT discriminator running: force UE preamble 24 (24+40=64=0 mod 64). If detected->0 => clean +40 mod 64 root-ENUMERATION offset (find the +40 source: root table abc[] usage, SSB-to-preamble mapping, or preambles_per_ssb); if not clean-linear => structural ZC-bin corruption in the RU DFT/extract. Fixed-preamble knob (OAI_UE_FIXED_PREAMBLE) + prach_probe.sh remain the harness. NOTE: shift 56720 is still REQUIRED to CAPTURE the energy (PRACH physically ~symbol13/offset57056 in the RU rxdata = a separate ~1-slot vrtsim delivery residue); the +40 is an independent ROOT-domain fault stacked on top. Canonical: rev-29.

## rev-30 (2026-07-04): ★★★ THE +40 WAS A GHOST — PRACH NEVER REACHES THE RU (slot_nz=0). Real bug = PRACH-slot UL delivery.
DECISIVE discriminator: forced UE preamble 24 -> DU STILL detects preamble 40 (same as forced-0). **Detected preamble is CONSTANT (40) regardless of what the UE sends.** RU [ORU PRACH RAW] probe: **slot_nz=0 across ALL 3400 PRACH occasions** — the RU rxdata for the PRACH slot is entirely EMPTY. => the "clean 19.4 dB preamble-40" detection is a deterministic DFT/correlation ARTIFACT OF ZEROS, not a real PRACH. 
**THIS INVALIDATES the entire rev-22..29 root/frequency/BFP/symbol-13/timing chase — all of it was chasing an artifact of correlating an empty window.** The two adversarial workflow verifiers were correct to refute every synthesis: the signal was never there. ORU_PRACH_SAMPLE_SHIFT, VRTSIM_UL_NOISE_STD, the root-index/BFP hypotheses = all moot for this.
REAL BUG (now unambiguous): the UE WRITES the PRACH (rev-23: 677 nonzero [VRTSIM UL TX] at slot-in-frame 19), but it NEVER lands in the RU's rxdata for slot 19 (slot_nz=0). SLOT-19-SPECIFIC: slot 19 = LAST slot of frame = the mixed TDD slot (2DL/4UL; mixed=6DL+4UL sym; PRACH in the UL symbols). Mid-frame PUSCH UL slots (16-18) deliver content; the frame-BOUNDARY slot (19) delivers zeros. => a vrtsim UL-read FRAME-BOUNDARY / ring-wraparound alignment fault for the PRACH slot. This is the same ~1-slot residue that has been the "attach-lottery" root all along, now pinned to: the last-slot-of-frame UL read returns zeros. NOTE rev-23's "UL sym present 0->100%" was PACKET-COUNT present, not content — for the mMIMO config (no attach, PRACH is the only UL) the content is zero at the boundary slot.
NEXT: fix the vrtsim UL read so the UE's slot-19 (frame-boundary) UL lands in the RU rxdata (candidates: ring wrap at frame end, read_sample vs UE write_sample for the last slot, the "aligned to frame boundary" client init). Verify via slot_nz>0 at the PRACH slot, THEN the real preamble (0/24) should be detected. Tools: OAI_UE_FIXED_PREAMBLE + prach_probe.sh + the [ORU PRACH RAW] slot_nz probe (the ground-truth energy check that finally cut through). Canonical: rev-30. ★ Lesson: should have checked slot_nz (is the signal even there?) BEFORE analyzing the detection — 8 revs of root/freq analysis on an empty window.

## rev-31 (2026-07-04): frame-boundary UL — the UL DATA REACHES the RU; bug = timestamp->slot rxdata MAPPING offset (not vrtsim alignment)
Instrumented (VRTSIM_IQ_DEBUG re-enabled + RU hw_log_level=info) the mMIMO fixed-preamble run. FINDINGS:
 - shm_td_iq_channel_rx is a DESTRUCTIVE read (memset 0 after memcpy) — a misaligned/duplicate read permanently loses data. Ring = CIRCULAR_BUFFER_SIZE 30720*14*20 = 8,601,600 samp = exactly 7 frames (big enough; NOT a small-ring overwrite).
 - vrtsim SERVER (RU) NEVER frame-aligns last_received_sample; only the CLIENT does ("client RX aligned to frame boundary", vrtsim.c:611). ROLE_SERVER branch has no equivalent -> server last_received starts at 0 (calloc).
 - BUT the RU vrtsim_read DOES return nonzero UL: [VRTSIM UL RX] nonzero=4375/4384 (a full PRACH OFDM symbol), ret=0, per-SYMBOL reads (nsamps=4384). So the UE's UL write DOES reach vrtsim_read at the same absolute channel sample. The read/write are aligned enough to deliver the bytes.
 - Slot distribution: RU reads nonzero UL at approx-slot 3 (336) & 4 (3664); UE writes nonzero at approx-slot 3 (100). But ru->common.rxdata for the PRACH slot (probe = slot 19) = slot_nz=0.
=> The UL data reaches the RU's vrtsim_read, but it is bookkept into the WRONG rxdata slot/offset (approx-slot 3/4) vs where the PRACH extraction/probe reads it (slot 19). A ~timestamp->slot MAPPING offset (vrtsim_timestamp_to_mu1_slot epoch, or the nr-oru UL-read rxdata fill offset), NOT a vrtsim delivery-alignment fault. The DATA is there; the RU indexes it to the wrong slot. This also explains why ORU_PRACH_SAMPLE_SHIFT (which shifts the extraction WINDOW within a slot) never helped — the data is in a DIFFERENT slot entirely.
NEXT: pin the nr-oru UL-read rxdata fill slot/offset vs the PRACH-extraction slot; align them (or fix the timestamp->slot epoch) so rxdata[PRACH-slot] gets the read data. Verify: slot_nz>0 at the PRACH slot. Workflow wf_6770ab93 (frame-boundary UL) analyzing in parallel. NOTE approx_frame.slot labels are epoch-dependent (UE MAC-slot 19 shows as vrtsim approx-slot 3) — use ABSOLUTE channel samples, not approx-slot, to reconcile. Canonical: rev-31.

## rev-32 (2026-07-04): ★★★ FRAME-BOUNDARY UL ROOT-CAUSED = frame-grid residue 917410 (~15 slots) = the rev-7 attach-lottery root, CONFIRMED
Workflow wf_6770ab93 (frame-boundary UL) + instrumentation + the EXISTING nr-oru.c:787 log converge on ONE mechanism, adversarially vetted:
 - vrtsim CLIENT (UE) aligns its radio grid to a ring frame boundary (residue 0; vrtsim.c:608-616). RU (SERVER) does NOT; the RU-L1 read grid is anchored by rx_initial_sync from get_timestamp() at an ARBITRARY wall-clock instant (perform_initial_sync, nr-oru.c:769) -> per-launch residue delta = initial_sync.sample % samples_per_frame.
 - MEASURED THIS RUN: **frame-grid residue = 917410** of spf=1,228,800 (nr-oru.c:787 LOG_A). 917410/61440 = **14.93 ~ 15 slots**. This shifts every RU rxdata read by ~15 slots vs the UE write grid => UE slot-19 PRACH is read into RU rxdata slot ~4 (19-15). CONFIRMED by IQ instrumentation: RU vrtsim_read returns NONZERO UL (4375/4384) at approx-slot 4 while [ORU PRACH RAW] slot_nz=0 at slot 19. The data reaches the RU; it's filed to the wrong slot.
 - Why slot-19-worst-case: it's the LAST slot; a +residue pushes its read across the frame boundary into next-frame slot-0 (DL, no UL) -> all zeros; and the PRACH ZC sits at the slot tail (offset 57056) = first to fall off the edge. This is EXACTLY the rev-7 "per-launch alignment residue -> UL-zeros face" attach-lottery root, now quantified (917410).
 - shm_td_iq_channel_rx is DESTRUCTIVE (memset after read); ring=7 frames (not overwrite). So a misaligned read permanently loses the PRACH.
FIX HISTORY: the initial_sync.sample frame-snap (floor+ceil) was tried 2026-06-10 -> 0/N, BUT against a ~0% same-day baseline = INCONCLUSIVE (the clean test "was never cleanly done" per the reverted-snap comment + the adversarial verifier). Verifier caveat: snapping .sample alone shifts sync_offset (perturbs DL). CLEAN RE-TEST now running (ORU_FRAMEGRID_SNAP=1 env, nr-oru.c perform_initial_sync; today's harness has a GOOD baseline). Decisive: UE-syncs+slot_nz>0 = fixed; UE-never-syncs = snap breaks DL -> pivot to decoupling UL-read-grid from DL-sync (align server last_received independently, or use vrtsim-returned *ptimestamp for the rxdata fill slot). NOTE the +40 preamble (rev-22..29) was a GHOST of correlating this empty window; the real bug is this residue. Canonical: rev-32.

## rev-33 (2026-07-04): ★★★★ FRAME-BOUNDARY UL FIXED BY THE SNAP — the rev-7 attach-lottery root is SOLVED (clean test the 06-10 attempt never did)
CLEAN RE-TEST of the frame-grid snap (ORU_FRAMEGRID_SNAP=1, nr-oru.c perform_initial_sync: snap initial_sync.sample UP to the ring frame boundary so residue=0) on a GOOD-baseline day. RESULT vs no-snap:
 - residue 952992 -> SNAP -> residue 0 (applied, logged).
 - UE STILL SYNCS (sync=1) — the snap did NOT break DL (the adversarial verifier's sync_offset-perturbation worry did NOT materialize on the clean test; the old 0/N was purely the ~0% bad-day baseline).
 - DU PRACH: was a CONSTANT ghost preamble-40 @ 19.4 dB, 0 RARs (correlating zeros). NOW: REAL 48 dB energy, a SPREAD of preambles (39,24,18,25,45,1,2,11,63,49...) delay 0, and **2 RARs SUCCEEDED** (RAR_ok=2, Msg2 decoded). A successful RAR handshake is IMPOSSIBLE from a ghost => the real PRACH now reaches the DU. The frame-boundary UL delivery is FIXED.
 - (The [ORU PRACH RAW] probe still prints slot_nz=0 — now a stale wrong-offset artifact; the receive_prach EXTRACTION at slot_start+shift gets the data, proven by the 2 successful RARs. Do not trust the probe post-snap.)
THE +40 GHOST IS FULLY EXPLAINED+GONE: it was correlating the empty (residue-misaligned) window; snap delivers real PRACH -> real spread, not a fixed 40.
REMAINING BLOCKER (known, tooling built): 48 dB SATURATION (zeroCorrelationZoneConfig=0 => N_CS=0, no noise) -> DU detects a SPREAD of roots -> mostly wrong RAPID -> 93/95 RARs fail (only 2 hit preamble 0). FIX = the per-antenna independent UL noise from rev-25 (VRTSIM_UL_NOISE_STD) to raise I0 -> clean single detection of the UE's actual preamble -> RAR reliably -> Msg3 -> attach. Testing SNAP + NOISE=100 now. Msg3=0 so far (post-RAR UL PUSCH) is the next thing to watch (should also be fixed by the snap since it's the same UL grid).
KNOBS for mMIMO attach: ORU_FRAMEGRID_SNAP=1 (frame-boundary, THE fix) + VRTSIM_UL_NOISE_STD (de-saturate) + gNB 1TX/4RX + UE 1x1 + VRTSIM_UL_READ_ADVANCE=0. If snap+noise attaches, promote ORU_FRAMEGRID_SNAP=1 to DEFAULT (it's the rev-7 root fix). Canonical: rev-33.

## rev-34 (2026-07-04): attenuation confirms 48 dB is a true ratio (I0~0), not overflow; SNAP = the frame-boundary fix. Remaining = intermittent ZC spread.
Added VRTSIM_UL_ATTEN_SHIFT (per-antenna right-shift, de-saturate the coherent Nrx combine without touching it). Test snap+shift+atten=2: DU energy STILL 48.0 dB, spread of roots, 0 RARs. => attenuation is scale-INVARIANT for the detection ratio (signal/I0 with I0~0) — it is NOT a fixed-point overflow, it's "no noise floor". So neither attenuation (rev-34) nor white noise (rev-33, made it WORSE: false-alarms) cleanly de-saturates.
BEST CONFIG = SNAP-ALONE (ORU_FRAMEGRID_SNAP=1 + ORU_PRACH_SAMPLE_SHIFT=56720, no noise, no atten): real 48 dB PRACH + **2 RARs succeed** out of ~95. shift=0 gives 0.0 dB (PRACH genuinely at symbol13/offset57056 = the mixed-slot UL symbols; snap fixes the ~15-slot GROSS offset, shift captures the within-slot symbol-13 position — BOTH needed).
REMAINING BLOCKER: after the snap, the PRACH reaches the DU but the detection SPREADS across roots at the 48 dB cap (N_CS=0 distinct roots) — root 0 (UE's) is detected cleanly only ~2% of occasions (=> 2 RARs), the rest spread to wrong roots => wrong RAPID => RAR fail. This is intermittent per-occasion ZC corruption/jitter (residual sub-slot timing after the gross snap fix; delay field scatters 0..54). NOT a constant offset (that was the pre-snap ghost). Candidates for the remaining ~2%->reliable: reduce residual sub-slot jitter (deeper dilation ts=0.5? per-slot read timing), or raise I0 to differentiate roots below the 48 cap WITHOUT adding root-false-alarms (structured noise, not white). 
NET SESSION RESULT: massive-MIMO UL went crash -> 4.5 Gbps FH -> full RA -> **frame-boundary UL FIXED (snap) -> real PRACH at DU -> 2 RARs**. The rev-7 attach-lottery root is SOLVED in substance (snap, clean-tested). Attach not yet 100% (intermittent ZC spread = the last, separate layer). Knobs (all env, backed up): ORU_FRAMEGRID_SNAP (nr-oru.c .bak_framegridsnap — THE fix), ORU_PRACH_SAMPLE_SHIFT, VRTSIM_UL_READ_ADVANCE, VRTSIM_UL_NOISE_STD, VRTSIM_UL_ATTEN_SHIFT (vrtsim.c .bak_ulatten), OAI_UE_FIXED_PREAMBLE, prach_probe.sh harness. Canonical: rev-34.

## rev-35 (2026-07-04): CORRECTION — 0 real RARs; the ONE remaining blocker = DU detects the WRONG preamble (ZC false-peak from residual jitter)
CORRECTION to rev-33's "2 RARs succeeded": the 2 were RAR-Msg2 DECODES that FAILED the RAPID check — UE log: "Received RAR preamble (24) doesn't match the intended RAPID (0) -> RAR reception failed". So ZERO true RAR successes. The DU detects the WRONG preamble (24, varying 18/49/6/63/... per occasion) instead of the UE's forced 0, sends RAR with the wrong RAPID, the UE rejects it, never sends Msg3 -> "MSG3 ULSCH with no signal" -> "RA failed at WAIT_Msg3". So **Msg3 is NOT a separate blocker — it's a downstream symptom of the wrong PRACH detection.** Attach rate ~0%.
=> EXACTLY ONE bug left: post-snap the REAL PRACH reaches the DU but is detected as a SPREAD of WRONG roots (varying per occasion, clean 48 dB, delay 0..54). With N_CS=0 (distinct roots) a pure timing offset should keep the same root at a shifted delay — so the varying-wrong-root spread = ZC cross-correlation false-peaks under residual sub-slot timing jitter (delay 0..54), where for large tau a false root peak exceeds the true root-0 peak. Fix the detection to reliably yield preamble 0 => RAPID matches => Msg3 => attach. Ruled out: overflow (atten ÷4 = 48 dB unchanged, true ratio I0~0), white noise (rev-33 made it worse). 
Workflow wf_a1018853 running (spread mechanism + fix: zeroCC>0 vs jitter-reduction vs structured-noise vs 1-preamble, adversarially vetted). Empirical snap+ts=0.5 running in parallel (is the jitter real-time-race-driven -> deeper dilation tightens delay->0?). Canonical: rev-35.

## rev-36 (2026-07-04): the wrong-preamble is SUBCARRIER-DOMAIN ZC DISTORTION (code-proven), NOT timing/jitter/noise
Workflow wf_a1018853 (spread mechanism): synthesis REFUTED, but the adversarial verifier CODE-PROVED (nr_prach.c:480-640) the mechanism:
 - N_CS=0 => preamble_offset==preamble_index (64 DISTINCT roots); the argmax outputs max_preamble=ROOT with delay as a SEPARATE non-labeling output (line 636). => a timing offset of ANY magnitude keeps the winner on root u0 and only moves the delay bin — it can NEVER make a different root win. Cross-root floor = N=139 = 21.4 dB below the N^2 auto-peak, so a clean 48 dB WRONG root is IMPOSSIBLE from timing.
 - The ts=0.5 run locking on a CONSTANT wrong root (2@delay0, 40@delay2) is the smoking gun: under pure constant timing the root would stay 0. A constant wrong root at delay~0 => the extracted 139-sample ZC is a GENUINELY DIFFERENT sequence = real SUBCARRIER-DOMAIN DISTORTION (wrong start subcarrier / K-factor / k1 / stride-decimation x_u0[a*n]=x_{u0*a^2 mod N} / reorder-wrap in the RU->DU freq extraction). Jitter is only the TRIGGER that varies WHICH wrong root wins per occasion; the distortion is the mechanism.
 - REJECTED (with proofs): zeroCC>0 (only re-labels a delayed peak to a cyclic-shift of the SAME root; does nothing to energy on different ROOTS), structured/white noise (4 RX are byte-identical coherent copies; non-coherent combine scales true+false equally; can't change argmax), static ORU_PRACH_SAMPLE_SHIFT trim (time shift = phase ramp = cyclic shift on SAME root; can't relabel a root), timescale=1.0 (abandons dilation).
REAL FIX = make the RU PRACH extraction SUBCARRIER-EXACT: receive_prach (nr-oru.c ~510) -> rx_nr_prach_ru_internal (nr_prach.c) -> xran_oru_send_prach (oaioran_ru.c) — verify the 139 ZC subcarriers grabbed at the correct start subcarrier (msg1_FrequencyStart/PRB130, K/k1), UNIT STRIDE, correct order, intact non-wrapped DFT on one whole B4 ZC repetition.
DECISIVE DIAGNOSTIC + single-UE guardrail (implemented): OAI_PRACH_ONLY_PREAMBLE=N bounds the DU matched-filter search to root N (nr_prach.c:480 loop, env-gated; nr-softmodem rebuilt; run_du.sh passthrough). Testing OAI_PRACH_ONLY_PREAMBLE=0: **if it ATTACHES => root-0 energy is present-but-out-argmax'd (distortion adds spurious roots but preserves root0) => attach pipeline works end-to-end; if NO detection => distortion MOVED root0's energy to a wrong root => must fix the subcarrier extraction.** Either way decisive. Canonical: rev-36.

## rev-37 (2026-07-04): ★★★★ DIAGNOSTIC CONCLUSIVE — root-0 energy PRESENT; guardrail -> 81/100 RARs; frontier = Msg3 (slot-18 PUSCH "no signal")
OAI_PRACH_ONLY_PREAMBLE=0 (bound DU matched-filter to root 0; nr-softmodem rebuilt, nr_prach.c .bak_onlypre) + snap + shift + UE-forced-0:
 - DU detects preamble 0 at 48 dB (root-0 energy IS present) => DIAGNOSTIC: the subcarrier distortion ADDS spurious roots that out-argmax root 0 but does NOT destroy root-0 energy. (Delay still jitters 0..45.)
 - **RARs 0 -> 81/100 SUCCEED** with intended RAPID 0. PRACH->RAR handshake now works reliably.
 - Attach STILL no: UE transmits Msg3 (81x @ slot 18) but DU "MSG3 ULSCH with no signal" (959x) -> "Contention resolution failed" (81x) -> RA failed WAIT_Msg3. Msg3 is a REAL next blocker.
FRONTIER = Msg3 PUSCH UL delivery at slot 18: same UL-delivery class as the PRACH, one slot over. PRACH (slot19 mixed/LAST) reaches DU via snap + PRACH-specific ORU_PRACH_SAMPLE_SHIFT (56720~sym13); Msg3 PUSCH (slot18 plain UL) gets snap but nothing compensates its within-slot position -> empty. Hypothesis: general UL within-slot ~57056 offset; PRACH shift covers slot19 only; PUSCH needs equivalent. NEEDS: probe slot-18 RU rxdata (nonzero=distortion / zero=delivery).
SESSION ARC: attach STRUCTURALLY IMPOSSIBLE (0%, ghost) -> frame-boundary FIXED (snap) -> PRACH working (81 RARs) -> Msg3 frontier. Guardrail OAI_PRACH_ONLY_PREAMBLE = single-UE-only (masks subcarrier distortion; real fix = subcarrier-exact PRACH extraction, rev-36). Canonical: rev-37.

## rev-38 (2026-07-05): Msg3 probe BLOCKED by bad-day sync (box up 12 days); frontier + hypotheses stand
Attempted to probe Msg3 (slot-18) UL delivery to classify it (delivery/timing vs within-slot-offset vs downstream). Two obstacles:
 1. RAR success is PER-LAUNCH flaky even with the OAI_PRACH_ONLY_PREAMBLE=0 guardrail: rev-37 got 81/100 on ONE good launch, but subsequent launches got 0 (root-0 energy per-launch above/below threshold = residual distortion varies per launch). Gating the harness on Msg3-tx (GATE_MSG3=1, prach_probe.sh) requires a good launch.
 2. **The box drifted to a BAD DAY** (uptime 12 days; load low, hugepages free, procs clean, so NOT resource exhaustion): 16 launches across 2 batches all failed to even SYNC (UE never syncs; RU starts fine — "ORU South read thread started"). Per memory (rev-9/12) BAD-DAY is real for 273 at long uptime and needs a COLD POWER-CYCLE. VRTSIM_IQ_DEBUG (heavy) definitely broke Msg3 (RU too slow); switched to a lightweight per-UL-slot nonzero probe [ORU UL PROBE] in nr-oru south read loop (nr-oru.c ~712, .bak_ulprobe) — but couldn't harvest it because no launch synced.
STATUS UNCHANGED from rev-37 (the milestone): frame-boundary FIXED (snap), PRACH detection working via guardrail (81 RARs on good launch), Msg3 is the frontier. Msg3 hypotheses to test on a GOOD day (post cold power-cycle): (A) slot-18 UL not delivered (empty rxdata) = delivery/timing, a frame-boundary cousin; (B) delivered but at within-slot ~57056 offset (symbol 13 not 0) = general UL within-slot offset that the PRACH shift secretly compensates for slot 19 only -> ONE fix covers both; (C) delivered correctly = downstream DU PUSCH extraction. The [ORU UL PROBE] lines (slot=18 present? which symbol?) decide it in ONE good-launch run.
RECOMMEND: cold power-cycle the box for a fresh day, then run GATE_MSG3=1 with the lightweight probe (heavy IQ debug OFF) to harvest the slot-18 [ORU UL PROBE] and classify Msg3. Canonical: rev-38.

## rev-39 (2026-07-05 PM): ★★★★★ FIRST DETERMINISTIC-GEOMETRY ATTACH — the vrtsim UL alignment fully mapped and compensated

**ATTACH ACHIEVED** (1×1, 273 PRB, iq9, ts=0.25): `4-Step RA procedure succeeded` → `NR_RRC_CONNECTED` → `Registration Accept` → PDU session. Msg3 decoded crc_valid=1 **SNR 35.2 dB TAest 0**; sustained PUSCH 38.8 dB.

**The complete geometry (all measured, not tuned):**
- `ORU_FRAMEGRID_SNAP=1` — pins initial-sync residue to 0 (kills the per-launch lottery variable).
- `VRTSIM_UL_READ_ADVANCE=63935 = 61440 + 2495` — one slot (position skew) + sub-slot offset (measured via first-nz probe: PRACH sym0 first=2496, Msg3 sym10 first=2495 — uniform shift, 8.7× CP → was the LDPC-abort cause).
- `OAI_FH_UL_SLOT_DELAY=3` (new knob, oaioran.c pop-side) — DU processes slot N−3 per sync callback; UL U-plane arrives ~1 wall-slot late in this geometry; without it DU reads pre-arrival zeros. UL sym present 100%.
- PRACH sample shift **0** (the old 56720 hack obsolete), guardrail still OAI_PRACH_ONLY_PREAMBLE=0 (subcarrier-exact extraction still open for multi-UE).

**Causal chain reconstructed (the whole day in one line each):**
1. Original code read UL at +tx_advance (65536): rev-13 attaches were residue-lottery hits where 65536 ≈ aligned.
2. My earlier `VRTSIM_UL_READ_ADVANCE=0` "zeros fix" CREATED the +1-slot skew (reads trailed writer) → PRACH 56720 hack, label-shift, DU-delay all compensations stacked on a self-inflicted offset.
3. prach_probe.sh HARDCODED `=0` (line 20) — silently invalidated the first read-advance test (refutation was fake).
4. Ring semantics (shm_td_iq_channel.c): writes must lead the clock (TOO_LATE guard), reads at ≤clock never race — advance-based alignment is SAFE; server read waits on clock.
5. Label shift ≡ advance 61440 (same position AND wall-time transformation, different layer). Sub-slot 2495 remained → symbol-straddling FFT windows → energy present + CRC garbage (the 19.9 dB NAK staircase; staircase itself = slot-type SNR-estimator artifact).
6. Anchor shifts (snap −1 slot) are chicken-egg: UE re-syncs to shifted DL; skew is anchor-invariant. TX-advance ≠ the discriminator (both runners use 65536).

**Constants (mu=1, 122.88 Msps):** slot=61440, sym=4384 (sym0 4448), CP=288. 2495 provenance still unexplained (≈0.57 sym; NOT N_TA_offset 1600, NOT TA·1632; PRACH shows same shift with no TA applied) — works as measured constant; derive later if it drifts with config.

**Gate lesson:** GATE_MSG3 (>3 Msg3) misclassifies SUCCESS (1 Msg3, no retries) as failure — added GATE_ATTACH.

**Open:** (1) reproducibility count at 1×1 (lottery faces still exist: post-attach tries in same batch gave prach-sent/rar-0); (2) 4-RX massive-MIMO attach with this geometry; (3) subcarrier-exact PRACH extraction (multi-UE mandatory); (4) explain 2495.

### rev-39 addendum (2026-07-05 late): attach rate + the delay-50 RAR-face (next target)
Attach rate with the rev-39 geometry at 1×1: **1/13** (the geometry works; a dominant per-launch face blocks the rest).
**The face (reproducible 10+ consecutive launches):** PRACH detected every occasion at 43.6 dB but **delay 50** (attach run: delay 0); UE runs 100 RAR windows → 0 RA-RNTI DCI ("RAR reception failed" ×100). PHY indication conditions PASS early in run (I0 still low; RAPROC-COND cond_counter=1 cond_energy=1), so the loss is at/after the MAC RA or in RAR DL delivery. I0 also EMA-climbs (0→195) from the PRACH's own energy (guardrail scans preamble-0 every occasion), eventually approaching the gate — secondary issue, not the early-run blocker.
**Logging gap:** DU never logs "initiating RA procedure" (LOG_A(NR_MAC)) or Msg2 generation even on the ATTACH run — suppressed by log level → absence is NOT evidence. Next probe = one run with DU NR_MAC at info/analysis to answer binary: does the DU transmit RAR on the delay-50 face?
**Interpretation guess (unproven):** per-launch UE-client sub-slot residue (RU side is snap-pinned; UE side isn't) shifts the geometry by ~50 units between launches; delay-0 face = residue ≈ calibrated 2495; delay-50 = shifted. If RAR turns out to be transmitted, suspect UE-side DL timing on the same residue. A UE-side alignment pin (client-side snap analog) would collapse the lottery entirely.

## rev-40 (2026-07-05 night): ★★★★★ ATTACH LOTTERY DEAD — 7/7 deterministic attach (1×1). Root = frame-snap mapping error vs Ta4.
**RESULT: 7/7 consecutive cold-launch attaches** (was 1/13). Config: `ORU_FRAMEGRID_SNAP=1` (now SLOT-boundary) + `VRTSIM_UL_READ_ADVANCE=63935` + `OAI_FH_UL_SLOT_DELAY=3`.
**The RAR-face root-caused entirely from existing logs (zero instrumented runs):**
1. State machine: bad-face RAs all reached WAIT_Msg3 ⇒ DU TRANSMITTED every RAR; UE never decoded ⇒ not a MAC refusal.
2. Frame correlation: UE PRACH at frame F, DU detects at F+1 on bad launches, F on good — perfect across ~70 runs (the "delay 50" was a red herring; post-fix attach works WITH delay 50).
3. Mechanism: the rev-39 FRAME-boundary snap displaced the anchor by (spf−R) = up to 19 slots while keeping the label → label↔position mapping error. FH buffers file mod-20 (slot only) → error invisible until it exceeds **Ta4 (~3.5 slots)** → UL wraps into DU's NEXT frame → RAR addressed to the wrong RA window.
4. Measured threshold (34 runs): displacement ≤3 slots always GOOD, ≥8 always BAD, 4-5 mixed = the Ta4 edge. Anchor-parity hypothesis tested and killed (N=4 coincidence).
**Fix = one modulus:** snap to SLOT boundary (61440), not frame — displacement always <1 slot, permanently inside Ta4. Frame alignment never required: the UE's grid follows SSB content, not ring frame boundaries (its own client frame-alignment is cosmetic). Read advance 63935 unchanged (proven displacement-independent within the good zone).
**Method note:** the entire diagnosis came from correlating already-logged values (UE `aligned_sample`, RU `frame-grid residue`, UE PRACH frames vs DU RAPROC frames, RA state warnings) across the day's ~70 run directories. Log-side observables >> new instrumented runs.
**Next:** 4-RX massive-MIMO attach (running); multi-UE PRACH extraction (guardrail removal); 2495 provenance.

## rev-41 (2026-07-05 night): ★★★★★ 4-RX MASSIVE-MIMO ATTACH — try 1, full chain with IP
`NB_RX 4, NB_TX 1` @ 273 PRB/100 MHz/iq9/ts0.25: RA succeeded → RRC_CONNECTED → Registration Accept → **PDU Session Accept, UE IPv4 10.0.0.6**. Msg3 crc_valid=1 SNR 35.2 dB TAest 0; sustained PUSCH 38.8 dB; UL sym present 100%. Same stack as rev-40 (slot-snap + advance 63935 + UL_SLOT_DELAY=3) + the aatx OOB guard + vrtsim single-UE→4-RX duplicate-stream server path. PROBE_NB_RX=4 in prach_probe.sh.
**The asymmetric massive-MIMO bring-up (simple 1-TX UE → many-RX gNB) is COMPLETE for N=4 single-UE.**
Open next: (1) mMIMO UL gain experiment — lower channel SNR (chanmod/TX power/pathloss per user directive) and measure 1-RX vs 4-RX UL; the 4 identical copies (server duplicate) give combining gain only vs noise added per-antenna — needs VRTSIM_UL_NOISE_STD or chanmod per-antenna independence; (2) multi-UE PRACH extraction (guardrail OAI_PRACH_ONLY_PREAMBLE removal); (3) 2495 provenance; (4) N=1 rate at 4-RX (only 1 launch so far).

## rev-42 (2026-07-06 ~01:00): mMIMO ARRAY GAIN MEASURED (+6.0 dB exact) + PRACH guardrail DEAD + two new defects scoped
**Task results (user's 1-3):**
- **4-RX attach rate: 4/5** (miss = pre-PRACH DL-sync launch flake; attach machinery 11/11 today when synced).
- **PRACH subcarrier-exact detection CONFIRMED — no bug exists**: preambles 0, 1, 23(random), and 100 consecutive random preambles ALL detected index-exact (sequence-perfect ue-sent vs du-detected match). The historical "wrong preamble" was the broken time-geometry corrupting the correlation. Guardrail (OAI_PRACH_ONLY_PREAMBLE) obsolete. **Multi-UE PRACH prerequisite met with zero code.**
- **mMIMO UL array gain: +6.0 dB MEASURED** (clean 4-RX L1=4: ULSCH SNR 44.8 dB vs 1-RX 38.8) = textbook MRC over 4 coherent copies. THE massive-MIMO gain demonstration.
**New instrumentation:** ORU_UL_NOISE_STD (RU-side per-antenna independent UL noise, label-exact PRACH-slot skip — vrtsim-side injection unusable post-slot-snap since vrtsim can't know the label grid) + ORU_UL_NOISE_ANT_MASK (per-antenna mask). Noise 800→PUSCH ~1 dB, 250→~6.4 dB (1-RX attaches; Msg3 fails below ~3 dB).
**Estimator gotcha:** reported ULSCH SNR ≈ combined/N_ant under independent noise (all-noisy 4-RX read 6.4 = 12.4−6; mask-14 read 7.5 ≈ 13.7−6) — use throughput or clean-signal SNR for gain accounting.
**CONFIG TRAP FIXED:** sweep's antenna patch is CHANMOD-gated → with CHANMOD=0 the gNB L1 block stayed nb_rx=1 (FH carried 4 streams, L1 decoded antenna 0 only; rev-41's attach was L1=1). run_iq_sweep.sh preflight now patches L1 nb_rx=NB_ANT_RX.
**NEW DEFECT (open): 4-RX per-TB decode instability at high SNR** — clean 4-RX: 19 ACK vs 25 NAK at IDENTICAL 38.8-44.8 dB, throughput 7-14 Mbps (vs 60 at 1-RX). NOT amplitude saturation (VRTSIM_UL_ATTEN_SHIFT=1 moved SNR 44.8→38.8 exactly but NAK pattern unchanged). Signature = intermittent per-antenna stream corruption (stale/mislabeled slots on some eAxC). Suspects: per-antenna arrival jitter vs read_slot copy, per-eAxC buffer rotation. Also blocks the noisy-arm throughput gain (0.6-0.8 Mbps at both 1-RX and 4-RX noisy).
**Perspective:** single-UE UL is rank-1 — MRC gain only shows vs independent noise; multi-UE (the end goal) is where 4-RX pays structurally (MU-MIMO separation).

## rev-43 (2026-07-06): "4-RX instability at high SNR" DISSOLVED — saturation refuted, deficit was a UNITS ARTIFACT
User asked: is the high-SNR instability saturation? **NO — and there was no instability at nominal levels at all.**
Chain: (1) level sweep via VRTSIM_UL_ATTEN_SHIFT {0,1,2} → 44.8/38.8/32.8 dB, early-NAK ratio unchanged → not amplitude-dependent in the sane range; (2) shift 4 (÷16, ~20 dB) collapses decode at BOTH 1-RX and 4-RX → a separate generic FIXED-POINT PRECISION FLOOR (reported SNR healthy, LLR path dead) — lab-knob limit, don't operate below ~÷4 amplitude; (3) iq16 = same → BFP exonerated; (4) RU probe: 4 antennas byte-identical; DU post-decompress probe ([PUSCH ANT]): byte-identical → per-antenna path CLEAN end-to-end; (5) [UL SYM MISS] logger: all misses boot-transient (f=0), zero during traffic; (6) MCS reaches 28 and ACKs at 4-RX; (7) **clean 1-RX control on the same stack: 16.7 wall ≈ 4-RX's 14.2 wall** — the "60 vs 14" deficit was wall-vs-sim units confusion (memory's numbers are sim = wall/ts). Both ≈ healthy ~57-67 sim supply-limited ceiling. Early NAK traces (19A/25N some runs) = attach/ramp-phase transients; final throughput identical whether 1 or 25 early NAKs.
**Genuine residual defect (open, small): UL SNR estimator reports combined/N_ant under independent per-antenna noise, and OLLA/MCS consumes it → at low SNR the scheduler cancels the array gain (4-RX noisy throughput ≈ 1-RX noisy despite +6 dB true SINR). Fix target: noise-power sum-vs-average across antennas in nr_ulsch SNR estimation.**
New DU knob/instrumentation kept: OAI_PUSCH_ANT_DEBUG ([PUSCH ANT] per-antenna signature), [UL SYM MISS] per-miss logging (cap 2000), both zero-cost when off/quiet. Units rule now canonical: **summary.csv ul_mbps is WALL; sim = wall / XRAN_TIMESCALE.**

## rev-44 (2026-07-06): SNR-estimator MRC fix VALIDATED — array gain now converts to THROUGHPUT (3.4×)
Fix: phy_procedures_nr_gNB.c nr_fill_indication SNRtimes10 += dB_fixed_x10(nb_antennas_rx) (sum(S)/sum(N) was per-antenna average; post-MRC = sum/avg = +10log10(N)). No-op at 1-RX; DTX ratio untouched.
GOTCHA: default UL MCS = BLER-OLLA (ignores ul_cqi entirely; mixed-slot NAKs pin it at MCS 0 in the noisy regime) → validation and any low-SNR work needs UL_HARQ_RR=1 (SINR-MCS branch; knob ported to run_iq_sweep.sh preflight).
VALIDATION (noise 250, SINR branch): 1-RX MCS 8-9, 1.12 Mbps wall → 4-RX MCS 15-16, **3.79 Mbps = 3.4×** ✓ = exactly the +6 dB on the MCS table. Low-SNR mMIMO recipe: ORU_UL_NOISE_STD + UL_HARQ_RR=1 + the fix.

## rev-45 (2026-07-06 PM): ★★★★★ MULTI-UE ATTACH ACHIEVED — N=2 both UEs, MCS 28 each, ~165 Mbps sim aggregate (END GOAL REACHED)
**N=2: UE0 ip=10.0.0.22, UE1 ip=10.0.0.23, both RA first-try, both PDU sessions; simultaneous 80M UL: aggregate LCID4 goodput 41.2 Mbps wall = ~165 Mbps sim (~82 sim per UE ≈ single-UE ceiling EACH → ~linear N-scaling), MCS 28,28.**
**Root cause of the multi-UE UL wall (June + today): the server's DL tx_sample_advance is a POSITION shift (vrtsim_write line ~1117 adds it to the write timestamp), and multi-UE mode SCALES it ×num_ues (line ~455) → DL grid shifts +1 slot → UE's SSB-derived grid +1 slot → its UL returns +1 slot late → invisible under DL labels (the single-UE +1-skew bug reincarnated at the DL side).** Proven dilation-invariant (ts=0.125 dead ⇒ positional not timing), then fixed config-only: **ADV=32768 (×2 scaling = 65536 = the calibrated single-UE geometry)**. N=1-in-multi-UE-mode attach first try; N=2 attach (1 launch flake, then clean).
**Dead ends mapped (for the record):** UE -A ladder (30000: PRACH/RAR only; 61440: Msg3 delivered but CRC-garbage at first=2496 + flaky prep; 92160: Msg3 prep broken) — -A's effect is POSITIONAL (driver subtracts, L1 doesn't pre-add); ring TOO_LATE grace guard (refuted: reader consumes at clock≈P+4384, late writes land behind the destructive reader — grace can't exceed ~1 symbol; the shm_td_iq_channel.c VRTSIM_TX_LATE_GRACE env remains, default 0 = stock).
**June's "multi-UE wall" fully explained:** DL/SIB1-fails face = this position shift (gone on the fixed geometry); "chanmod breaks sync" untested today (chanmod path scales differently).
**Multi-UE recipe (canonical): `N_UE=N ADV=32768(for num_ues=2; general: 65536/num_ues) CHANMOD=0 VRTSIM_UL_READ_ADVANCE=63935 OAI_FH_UL_SLOT_DELAY=3 ORU_FRAMEGRID_SNAP=1 ORU_PRACH_SAMPLE_SHIFT=0 bash run_multi_ue.sh`** (+ post_reboot_prep.sh after reboot). NOTE: ADV=65536/num_ues keeps the POSITION geometry fixed; if deeper N makes the server's WALL budget tight, that must be solved separately (unscale the position add in code, keep a wall-only lead).
**2495 provenance (bonus, now explained):** the sub-slot constant ≈ tx_sample_advance mod slot (65536−61440=4096) minus N_TA-class offsets — the whole geometry constant family traces to the server DL advance being a position shift. The 63935 calibration absorbs it; changing ADV changes the required read advance (65536↔63935 pairing is calibrated; keep them together).

## rev-46 (2026-07-06 PM): opens #2/#3 CLOSED, #4 composes (3 vrtsim multi-UE bugs fixed)
**#2 CLOSED — DL advance unscaled (vrtsim.c):** deleted the `tx_sample_advance *= num_ues` block (it was a ring-POSITION scaling, not wall budget). `ADV=65536` (default) now attaches N=2 with no per-N arithmetic. Multi-UE recipe simplified: drop the `ADV=` override entirely.
**#3 CLOSED — chanmod + multi-UE (2 vrtsim bugs):** (a) `vrtsim_write_with_chanmod` fanned out over `peer_info.num_rx_antennas` (=1) → UE1..N DL streams unwritten; fixed to `total_dl_streams` for multi-UE server. (b) the modellist (non-CIRDB) path never populated `channel_desc_per_ue[]` → every DL actor bailed "channel_desc is NULL"; fixed to point all UEs at the single configured model. RESULT: **N=2 CHANMOD=1 both attach** (AWGN passthrough). Single-UE chanmod was the control (attached). June "chanmod breaks multi-UE sync" = these two NULL/short-bound bugs, not a timing wall. Distinct per-UE channels (real MU-MIMO diversity) still need CIRDB or per-UE modellist entries — follow-on.
**#4 COMPOSES, residual open — 4-RX gNB × N=2 UEs:** rewrote the multi-UE UL combine (was `stream=u*nbAnt+aarx`, assumed UE-tx==gNB-rx → OOB/double-read at 1-TX-UE→4-RX-gNB) to read each UE tx stream ONCE by `ue_conf.tx_offset` and add into every gNB antenna (rank-1 duplicate, matches the single-UE path). Regression: 1-RX N=2 still attaches ✓. But 4-RX N=2: DU comes up NB_RX 4, UEs **struggle to sync (13-20 attempts vs 2)** and Msg3 lands as no-signal → no dual attach (2/2 runs). NOT launch flake (1-RX N=2 = 2 sync attempts). A real nb_rx=4 × num_ues=2 DL-sync/UL degradation — deferred: the MU-MIMO *science* (spatial separation) needs distinct per-UE channels (#3 CIRDB) anyway, so single-stream-duplicate 4-RX+2UE is not the target config. New harness knob: `NB_ANT_RX` patches L1 nb_rx in run_multi_ue.sh (survives the bak-restore).
**Session net (rev-39→46): single-UE attach → deterministic → 4-RX +6dB gain (throughput-validated) → multi-UE N=2 (ideal + chanmod) → mMIMO×multiUE composed. 5 vrtsim/OAI bugs fixed today, all config/software.**

## rev-47 (2026-07-06): MU-MIMO Phase-0 scout — UL MU-MIMO NOT in OAI (3/3 layers block); SU-MIMO 2-layer IS the achievable path
Parallel read-only scout of OAI gNB UL (this tree). Unanimous: true UL MU-MIMO (2 UEs, same PRBs, spatial separation) is NOT supported at THREE independent layers:
1. **Scheduler = strict OFDMA.** pf_ul() rballoc_mask/vrb_map_UL skip-and-mark (gNB_scheduler_ulsch.c:2186-2193 search, :2306-2307 reserve) guarantees disjoint PRBs; UEs iterated sequentially, each marks RBs before next UE's rbStart search. Retx allocator identical (:1831-1858). No mu_mimo/coschedule flag anywhere on UL path.
2. **Receiver = single-user only.** nr_ulsch_channel_compensation MRC (nr_ulsch_demodulation.c:427-435, literal `// MRC`). MMSE path (nr_ulsch_mmse_2layers :683) is SINGLE-UE 2-LAYER (2 DMRS ports of the SAME PDU), scalar noise_var (:914-925), NO Rnn/IRC/covariance (grep empty). Per-UE independent decode loop (phy_procedures_nr_gNB.c:364) — co-scheduled UE = unmodeled noise. Supports 2 layers, nb_rx∈{2,4}.
3. **DMRS = all UEs port 0.** dmrs_ports=((1<<nrOfLayers)-1) always from bit 0 (gNB_scheduler_ulsch.c:2355), scid=0 hardcoded (primitives.c:749), scrambling=physCellId (cell-wide). No per-UE port/CDM/scid offset. BUT PHY estimator IS already per-DMRS-port (nr_ul_channel_estimation.c, get_dmrs_port) — it separates one UE's LAYERS; would separate 2 UEs IF the scheduler assigned distinct ports (it never does).
**CONCLUSION: true UL MU-MIMO = a RECEIVER+SCHEDULER build (joint H stack, MMSE-IRC with real Rnn, per-UE port planning, co-sched PRB path), not a flag. Large.**
**PIVOT (what IS achievable, reuses existing code): SU-MIMO 2-layer uplink** — ONE UE, 2 TX antennas → 2 spatial layers, separated by the EXISTING nr_ulsch_mmse_2layers at nb_rx=2/4. This exercises the identical array-receiver / spatial-multiplexing math and is fully supported. Requires: UE 2×N (2 TX), UL rank 2 (SRS ul_ri=1 or forced nrOfLayers=2), 64QAM+ for the MMSE branch (else ML-LLR path), distinct per-antenna channel signatures in the vrtsim combine (the Phase-2 steering-vector work — makes HᴴH invertible). Deliverable = 2-layer single-UE UL throughput ~2× rank-1 at good SNR.
**Also still valid: array-gain-for-many-users (OFDMA N-UE, each +6 dB) — already essentially done (rev-45/46), just needs the #4b budget fix for 4-RX.**

## rev-48 (2026-07-06): SU-MIMO 2-layer — infra built, BLOCKED at UE 2-TX transmit (OAI gap, not tunable)
Built (all correct, kept): (1) vrtsim server 2-layer steering combine — reads UE's N_L TX streams, mixes into nbAnt gNB antennas via orthogonal Walsh-Hadamard signs so H=[N_rx x N_L] is well-conditioned for the gNB 2-layer receiver (vrtsim.c single-UE read, ue.tx_ant>=2 branch). (2) gNB UL rank force OAI_UL_FORCE_LAYERS (get_ul_nrOfLayers, gNB_scheduler_primitives.c) — SRS gives no rank under vrtsim. (3) config chain: sweep writes ue_config "2x1", pusch_AntennaPorts patch (gates maxRank=min(uecap,ports)), UL DCI 0_1 auto for connected UE.
**WALL (deterministic): the OAI simulated UE with 2 TX antennas HANGS at RA/TX-init.** Isolation: identical stack, UE 1-TX attaches 6/14; UE 2-TX 0/3, clean HANG (no assert/crash) right after "Configured TDD patterns", BEFORE "N_TA_offset changed" (UE TX-thread) and "Initialization of 4-Step CBRA". 2-TX handshake is fine (UE synced/SIB1, no tx_ant-mismatch assert → server ue_conf=2 parsed OK). So the UE's 2-antenna UL TX/slot-loop stalls before it can start RA. This is a UE PHY/MAC 2-TX transmit gap (codebook precoding / TX-thread multi-antenna), not a config or tuning miss — exactly the "less-mature UL 2-layer path" the rev-47 scout flagged.
**CONSEQUENCE / PLAN FLIP:** SU-MIMO (1 UE, 2 TX layers) is blocked by a UE-side bug that needs UE PHY work — NOT achievable by tuning. MU-MIMO, though a larger gNB-side build (joint receiver + co-schedule + per-UE DMRS), uses **1-TX UEs (which WORK, rev-45/46)** and therefore does NOT hit this wall — it is now the more viable MIMO path despite being bigger. The vrtsim steering + multi-UE combine primitives (built) are reusable for it. Infra changes kept in tree (correct, dormant unless env set); SU-MIMO not validated → not a "pass".

## rev-49 (2026-07-07): SU-MIMO — rev-48 CONCLUSION WAS WRONG. 2-layer PHY WORKS end-to-end; only the TBS/throughput 2× is missing (OAI UL-MIMO gap).
**rev-48 RETRACTED:** the "UE 2-TX hangs, unfixable OAI gap" was FALSE. gdb on the "hang" showed a **SIGSEGV in shm_td_iq_channel_tx writing UE TX antenna 1** — my own vrtsim RING-SIZING BUG: `shm_td_iq_channel_create(name, ul_streams, total_dl_streams)` sized the UL region (client-write / server-read) by `total_dl_streams` (=UE RX=1), so the 2-TX UE's antenna-1 write overflowed the ring. Invisible for all prior configs (ul_streams==total_dl_streams: every 1×1 + symmetric multi-UE); SU-MIMO's 2-TX/1-RX is the first asymmetric case. **FIX: create(name, total_dl_streams, ul_streams)** — size each region by what it carries. (User's call to DEBUG rather than defer was correct.)
**SU-MIMO now works at the PHY (proven):** UE 2-TX runs+attaches (6-7/8, was 0). Forced UL rank-2 (two hooks: get_ul_nrOfLayers + set_ul_max_layers, both env OAI_UL_FORCE_LAYERS — the UE advertises a minimal cap=1 UL layer so maxRank must be forced; propagates to UE pusch maxRank via RRC → UE accepts 2-layer + uses DCI 0_1). PHY receiver confirmed processing **nrOfLayers=2** on ~1300 grants/run (Qm2+Qm6); ULSCH **crc_valid=1** at 2 layers → the gNB's 2-layer ML-LLR receiver SEPARATES the 2 spatial streams (made possible by the vrtsim orthogonal-Hadamard steering combine). Genuine UL spatial multiplexing, end to end.
**What's MISSING — the 2× throughput:** 2-layer per-slot TBS (22547, 22 CBs) is actually LESS than 1-layer (26122, 25 CBs) at identical rb0+273/sym0+13/mcs28/Qm6. nr_find_nb_rb→nr_compute_tbs DOES pass Nl=2 (TBS formula ×Nl), but the 2-layer DMRS overhead (num_dmrs_cdm_grps_no_data=2 + DMRS-symbol count) removes ~57% of data REs → net ~0.86× not ~1.9×. So the capacity gain is eaten by DMRS accounting. Recovering it = 2-layer UL DMRS-config tuning (single-symbol / 1 addl position / CDM), real OAI UL-MIMO work (consistent with rev-47: OAI UL rank>1 codebook TPMI "not implemented").
**Net:** SU-MIMO spatial multiplexing DEMONSTRATED (2 layers separated+decoded); throughput-2× pending a DMRS-overhead fix. Kept in tree: vrtsim ring fix (general bug fix, safe), vrtsim 2-layer steering, OAI_UL_FORCE_LAYERS hooks, UE_GDB wrap in run_ue.sh. Debug LOG_E instrumentation removed.

## rev-50 (2026-07-07): BF-branch integrated + UL MU-MIMO Phase 1 DONE (per-UE spatial signatures)
**Integrated (targeted port, not merge — forks diverged: their native fronthaul/oru vs our xran radio/fhi_72):**
- Cat-B codebook DL beamforming (apply_codebook_weights + oru_codebook_t + config) into nr-oru.c/.h, gated OFF (nb_fh_streams=0=passthrough); vrtsim timing usleep(1)->usleep(20). Session work protected first in local commit 5a4a9bd132.
- **REGRESSION ALL GREEN:** 1×1 attach (first-try sync, 0 flakes — usleep(20) may steady the lottery), SU-MIMO 2-layer (crc_valid=1), multi-UE N=2 (both attach ~147 sim). Build clean.
**Phase 1 (UL MU-MIMO channel): per-UE configurable spatial signatures in the vrtsim multi-UE combine.** Replaced the identical rank-1 duplicate (all UEs same signature -> H singular -> inseparable) with per-(UE,antenna) Q15 steering weight w[u][a]. Env VRTSIM_UL_MU_STEER="auto" (orthogonal DFT beams angle_u=u/nbAnt) or comma-list of per-UE spatial frequencies (cycles/ant) for the conditioning sweep. Default OFF = rank-1 duplicate unchanged (no regression). vrtsim.c multi-UE UL read.
**PROVEN (3 ways):** (1) injected W verified orthogonal per UE — UE0=[1,1,1,1] flat, UE1=[1,j,-1,-j] quarter-turn (inner product 0 = separable); (2) both UEs attach with steering ON (unit-mag rotation, MRC handles it); (3) per-antenna PUSCH data now DIFFERS across the 4 antennas (distinct phase ~27/163/-64/72°, magnitude preserved ~90) — was BYTE-IDENTICAL without steering. The sim now presents a rank-K UL channel = the precondition the joint MU-MIMO receiver needs.
**Knobs/instrumentation:** VRTSIM_UL_MU_STEER (run_ru.sh), OAI_MU_CHEST_DEBUG (per-antenna chest, env-gated; only sees ant0 during small attach PUSCHs — use [PUSCH ANT]/OAI_PUSCH_ANT_DEBUG instead). NEXT: Phase 2 per-UE DMRS ports, Phase 3 co-schedule same PRBs, Phase 4 joint MMSE-IRC receiver (the hard build).

## rev-51 (2026-07-07): UL MU-MIMO Phase 2 (DMRS ports) — mechanism + Msg3-fix; port-1 validation blocked
**Phase 2: per-UE DMRS port assignment** (gNB_scheduler_ulsch.c prepare_pusch_pdu, env OAI_UL_MU_DMRS): shift each UE's dmrs_ports bitmap by uid%N so co-scheduled UEs use distinct ports (PHY estimator already per-port). Off by default = unchanged.
**Bug found+fixed:** shifting Msg3/RA-phase PUSCH breaks RA — Msg3 MUST stay on port 0 (UE ignores a shifted port during RA -> gNB expects port 1, UE sends port 0 -> "MSG3 no signal" -> contention resolution fails, UE1 0/N attach while UE0-on-port-0 attaches). Proven: try2 UE0(port0)=1 UE1(port1)=0. FIX: gate the shift to CONNECTED UEs only (UE->ra==NULL). After gate: both UEs attach (Msg3 stays port 0), shift fires 12x for connected grants.
**STILL OPEN (2 issues):** (1) uid-based index unreliable — actual uids aren't 0/1, both mapped to port 0 in the passing run (need a real MU-pairing index, not uid%N); (2) port-1 CONNECTED PUSCH decode UNCONFIRMED — the rate-limited log + sync-lottery flakiness hid whether UE1 ever got 0x2 and decoded (attach succeeded but can't attribute to port-1 working vs both-on-port-0). Needs: proper pairing index + a targeted port-1-only connected-PUSCH decode test.
**META (the honest read across SU-MIMO + MU-MIMO Phases 1-2):** every phase hits OAI UL-MIMO immaturity — SU-MIMO 2-layer TBS not doubled (DMRS overhead), rank>1 codebook TPMI "not implemented" (rev-47), non-zero DMRS port breaks RA / DCI-0_1 port-encoding unverified. Plus sync-lottery flakiness (box 2-day uptime) costs multiple runs per test. Phase 3 (co-schedule same PRBs) = scheduler change; Phase 4 (joint MMSE-IRC receiver) = OAI has NOTHING, a major PHY build. Full UL MU-MIMO = genuine multi-week effort; Phase 4 is the crux.
**Phase 1 remains the solid banked deliverable** (per-UE spatial signatures, proven). Kept in tree (all env-gated OFF): VRTSIM_UL_MU_STEER, OAI_UL_MU_DMRS (connected-gated), OAI_MU_CHEST_DEBUG.

## rev-52 (2026-07-07): UL MU-MIMO PHASE 2 FIXED — distinct DMRS via SCID (port path is an OAI dead-end)
User pushed "can't we fix phase 2" — YES. Two sub-fixes:
1. **Index fixed:** replaced uid%N (uids aren't 0/1) with rnti->connection-order map (first connected UE=port/scid 0, second=1). Deterministic distinct.
2. **Port path PROVEN DEAD in OAI, SCID path WORKS:** a single UE forced to DMRS PORT 1 (OAI_UL_MU_FORCE_PORT=1) does RA+RRC on port0 fine but reg_acc=0 / attach=0 (3/3) — gNB cannot decode the connected PUSCH on port>0 (DCI 0_1 antenna-ports encoding for 1-layer-on-port-1 is unhandled). SWITCHED to distinct **SCID** (nSCID DMRS scrambling), both UEs stay on the working port 0: single UE forced scid=1 ATTACHES (reg_acc=1); **N=2 with per-UE scid (OAI_UL_MU_SCID=1) BOTH ATTACH** (order0->scid0, order1->scid1). Quasi-orthogonal DMRS the gNB estimates per-scid, no port-1 gap.
**Phase 2 DONE:** per-UE distinct DMRS scrambling + Phase-1 per-UE spatial signatures = the gNB now has both distinct-channel prerequisites for co-scheduled UEs. Knobs (env-gated OFF): OAI_UL_MU_DMRS (enable), OAI_UL_MU_SCID (scid mode = the working one), OAI_UL_MU_FORCE_PORT/SCID (isolation). DMRS shift gated to connected UEs (UE->ra==NULL) — Msg3 must stay port0/scid0.
**Progress:** Phase 1 ✅ (spatial sigs), Phase 2 ✅ (distinct DMRS via scid). NEXT Phase 3 = co-schedule both UEs on same PRBs (rballoc_mask, gate behind a pairing flag). Then Phase 4 = joint MMSE-IRC receiver (the big build — OAI has none). Lesson: OAI UL-MIMO port/layer DCI encoding is broken, but scid-based DMRS distinction is a viable workaround.

## rev-53 (2026-07-08): UL MU-MIMO PHASE 3 DONE — 2 UEs CO-SCHEDULED on same PRBs
Phase 3 (env OAI_UL_MU_COSCHED): the UL scheduler's disjointness comes ONLY from the rballoc_mask mark-used step (rb_start_sched doesn't advance per-UE). For CONNECTED UEs (UE->ra==NULL) SKIP the mark + the free-RB decrement -> the next connected UE's rbStart search finds the same RBs free -> both granted the SAME allocation. Gated to connected (RA/attach stays OFDMA else they'd collide pre-receiver). Off => unchanged OFDMA.
**PROVEN:** both UEs attach (PDU sessions), then [MU COSCHED] shows 2+ distinct rntis granted SAME PRBs rbStart=0 rbSize=273 (full band overlap). ACK/NAK mix = the expected collision (no joint receiver yet). Registration completes OFDMA (each UE's NAS PUSCH lands while the other is idle); the overlap bites during simultaneous data.
**Full MU-MIMO stack now assembled (Phases 1-3):** VRTSIM_UL_MU_STEER (per-UE spatial signature) + OAI_UL_MU_SCID (distinct DMRS scrambling) + OAI_UL_MU_COSCHED (same PRBs). The gNB now receives 2 spatially-distinct, DMRS-distinct signals on identical spectrum = the complete INPUT the Phase-4 joint receiver needs. Decode collides until Phase 4.
**Progress:** P1 ✅ spatial sigs, P2 ✅ distinct DMRS(scid), P3 ✅ co-schedule. **NEXT = PHASE 4: joint MMSE-IRC receiver** — stack both UEs' per-antenna channel estimates into one H=[N_rx x K], MMSE-IRC to null UE_j while decoding UE_i, restructure the per-UE-independent decode loop (phy_procedures_nr_gNB.c:364). OAI has NOTHING here = the from-scratch PHY build, the crux.

## rev-54 (2026-07-08): UL MU-MIMO Phase 4 — existing MRC PARTIALLY separates co-scheduled UEs; joint MMSE-IRC receiver CONFIRMED REQUIRED
Tested whether the orthogonal Phase-1 steering (h_0 ⊥ h_1) lets the EXISTING per-UE MRC receiver separate the co-scheduled pair (MRC of orthogonal channels theoretically nulls the interferer: conj(h_0)·rx = |h_0|²x_0 + (h_0^H h_1)x_1 = |h_0|²x_0). RESULT: PARTIAL — one UE crc_ok=17/fail=22, other crc_ok=0/fail=10, both MCS->0, aggregate LCID4 low. So the channels ARE separable (one UE punches data through) but MRC is inadequate: the quasi-orthogonal SCID DMRS (port-1 is an OAI dead-end so we can't use FD-OCC orthogonal ports) corrupts each UE's channel estimate -> imperfect nulling -> collision. **Joint MMSE-IRC receiver is genuinely required** — not optional, not shortcuttable via orthogonal beams.
**Phase 4 design (the remaining build):** when 2 UEs co-scheduled, stack their per-antenna channel estimates into H=[N_rx x 2] and run MMSE-IRC — the EXISTING nr_ulsch_mmse_2layers (nr_ulsch_demodulation.c:683) already inverts a 2-column HᴴH for a single UE's 2 layers; reuse it with layer0=UE_i, layer1=UE_j, take output i. INVASIVE: the receiver is per-UE-independent (nr_ulsch_procedures loop phy_procedures_nr_gNB.c:364); needs restructure to (a) thread the partner UE's chFext into the desired UE's demod, (b) run the 2-stream separation, (c) route each output stream to its UE's LLR/decode. Plus DMRS-estimation improvement (scid quasi-orthogonal -> estimate corruption). = multi-day from-scratch PHY build, the crux.
**SESSION SCORECARD (UL MU-MIMO):** P1 spatial sigs ✅, P2 distinct DMRS via scid ✅, P3 co-schedule same PRBs ✅, P4 receiver = designed + confirmed-required, NOT built. The entire MU-MIMO FRONT-END is complete and validated; only the joint receiver remains — a well-scoped major PHY investment.

## rev-55 (2026-07-08): UL MU-MIMO Phase 4 — joint MMSE-IRC receiver FIRST CUT (compiles+fires, not yet correct); pushed
Implemented the joint receiver in inner_rx (nr_ulsch_demodulation.c ~1143): for a co-scheduled connected UE (gate: rb_size>137 large alloc = co-sched data not RA/registration, distinct rnti, matching rb_start/rb_size) build a 2-layer chFext [layer0=self via own ul_ch_estimates, layer1=partner via gNB->pusch_vars[partner].ul_ch_estimates], run the existing nr_ulsch_channel_compensation + nr_ulsch_mmse_2layers into LOCAL 2-layer buffers, then nr_ulsch_compute_llr on the separated self-stream (comp2[0]) into this UE's llr[0]. Symmetric (each UE nulls the other). Env OAI_UL_MU_IRC.
**STATUS: compiles, IRC branch fires (irc_fired=8/run), but does NOT correctly separate.** With IRC on: UE0 attaches (3/6) but UE1 never (ra_ok=0), decode corrupts when IRC active -> the MMSE-IRC DSP handoffs are wrong: partner-channel extraction alignment (soffset/dmrs_symbol), mmse scaling (log2_maxh from a local comp vs shared), and LLR magnitude from the separated stream all need debugging. Ungated first cut broke attach entirely; the rb_size>137 gate lets UE0 attach but UE1 still fails.
**Default SAFE:** OAI_UL_MU_IRC OFF (default) regression clean — both UEs attach (rev confirmed). The WIP receiver only activates when explicitly enabled.
**Phase 4 = the multi-day DSP-debug build, now SCAFFOLDED.** Taken from "OAI has nothing" to "first implementation exists, fires, gated off." Remaining: debug the 3 DSP handoffs (extraction alignment, scaling, LLR mag) + likely improve DMRS channel estimation (scid quasi-orthogonal corrupts estimates -> even correct MMSE limited). Committed+pushed to bck (44dd9d2fd7).
**SESSION MU-MIMO FINAL:** P1 spatial sigs ✅, P2 distinct DMRS/scid ✅, P3 co-schedule same PRBs ✅, P4 receiver = scaffolded (fires, needs DSP debugging). Entire front-end DONE+validated; receiver is the first-cut WIP.

## rev-56 (2026-07-08): Phase-4 Stage-0 tooling IN + 2 receiver bugs found/fixed; next blocker = scheduler->PHY co-sched marker
Saved the full Phase-4 plan: MU_MIMO_PHASE4_PLAN.md (Stage0 tooling -> Stage1 genie fork -> Stage2 DSP handoffs / Stage3 estimation -> Stage4 result). STARTED it:
- Stage-0 metric added to the IRC branch ([MU METRIC]: |chSelf|/|chPart|, log2_maxh, output & LLR abs-mean/max; [MU DIAG]: normal-path rxFext/chFext magnitude). Paid off immediately.
- BUG 1 FIXED: IRC re-extracted the self channel with its own extract call -> reuse the normal-path rxFext + chFext[0] (only extract the PARTNER now).
- BUG 2 FIXED: IRC fired on symbols with NO received signal (rxFext~0, phantom/stale grants) -> added a received-energy guard (skip IRC if rxFext trivial).
- NEXT BLOCKER (found via metric): IRC still breaks UE1 attach — during UE1's registration, UE1 transmits (passes signal gate) but the detected partner UE0 is IDLE (stale channel estimate), so the 2-stream MMSE nulls a PHANTOM -> corrupts UE1. Need reliable "both UEs genuinely co-scheduled + transmitting THIS slot" detection = a SCHEDULER->PHY co-sched pair marker (per-slot), not PHY-side rb_size matching. Then the 3 DSP handoffs (Stage 2) can be debugged on a clean both-attached data phase.
STATUS: default (OAI_UL_MU_IRC off) still clean. Receiver is closer but not working; remaining = co-sched marker plumbing + DSP handoffs + likely estimation = the multi-day build, now with tooling + 2 bugs cleared. Committed+pushed (gated off).

## rev-57 (2026-07-08): rev-56 hypothesis OVERTURNED by logs — attach-killer is CO-SCHED-DURING-ATTACH, not the IRC receiver
Investigated run multiue_20260708_144455 (both UEs got C-RNTIs). Evidence:
- UE0 (7cf7) attaches + runs full-band UL fine (crc_valid 1, SNR 38.8, HARQ cycling) via plain MRC.
- The instant UE0 connects: [MU COSCHED] rnti=7cf7 rbStart=0 rbSize=273 -> UE0 holds the WHOLE band every slot AND COSCHED marks those PRBs free to the RA scheduler.
- UE1 (16b8) gets C-RNTI (PRACH+RAR ok) then RA fails at WAIT_Msg3 with ZERO decoded Msg3 (no ULSCH rnti 16b8 trace). Its Msg3 lands on top of UE0 full-band data; during RA the gNB has NO channel estimate for UE1 => nothing can separate them. Msg3 MUST be interference-free.
TWO SEPARATE DEFECTS:
- D1 (attach-killer): co-scheduling applied during a UE's RA. NOT the receiver. rev-56's "phantom partner corrupts UE1 registration" was WRONG — UE1 never reaches the receiver, it dies in the scheduler at Msg3. (rev-45 plain multi-UE attaches N=2 -> COSCHED is the regressor.)
- D2 (IRC math, downstream): when IRC fires on connected 7cf7, metric = partner=0 |chSelf|=94 |chPart|=0 outAbsMean=0 llr=0. Partner detected is a STALE pusch_pdu (rb match, no live channel), and mmse_2layers with a degenerate 2nd column zeroes BOTH streams incl the good self => destroys self decode whenever partner channel absent/mis-extracted.
CORRECTED PLAN: (1) gate COSCHED+IRC on BOTH-UEs-CONNECTED (protect attach; few lines) -> UE1 attaches. (2) co-sched shared band + fire IRC only on genuinely-live pairs (require chPart!=0). (3) THEN debug IRC DSP (partner extraction + MMSE scaling) on a clean two-real-UEs slot = the real Stage-2. IRC still needed (same-PRB MU-MIMO), just not the attach blocker. Default OAI_UL_MU_* off = clean.

## rev-58 (2026-07-08): attach-guard + IRC partner-guard applied; NEW gating blocker = vrtsim multi-UE DL-sync wall
Applied D1 fix (pf_ul: freeze co-sched whenever ANY UE mid-RA -> Msg3 gets clean PRBs) + D2 fix (IRC skips to MRC when |chPart|~0, no longer zeroes the self stream). Built clean. 3-try test:
- try1/2: UE0=0 too (no attach at all). try3: UE0 attaches+runs (rnti 114b, cosched+irc fire), UE1=0.
- ROOT of UE1=0 now: UE1 ue1.log = repeated "synch Failed" — UE1 never locks SSB/SIB1, never reaches PRACH. This is UPSTREAM of my scheduler/receiver work = the documented vrtsim MULTI-UE DL-SYNC WALL (2nd UE can't sync; ul_ceiling note: "no-chanmod DL/SIB1 fails, chanmod breaks sync").
- Env: uptime 2d22h, load 5.40 (5-min) = recent HIGH load = bad-day-ish -> sync lottery worse. UE0 itself saw 151 "synch Failed" before locking in try3 (sync is flaky/slow for BOTH; UE0 won the lottery within ATTACH_WAIT, UE1 didn't).
VERDICT: the two fixes are correct for the bugs they target (proven from run 144455 logs) but CANNOT be validated end-to-end until BOTH UEs reliably attach. The gating problem is now multi-UE DL sync (vrtsim internals) + load-driven attach lottery — a separate hard wall, NOT the MU scheduler/receiver. Fixes committed, all OAI_UL_MU_* default OFF = clean. Next fork: (A) fix vrtsim 2nd-UE DL sync, (B) low-load retry-hunt to catch a lucky dual-attach + observe receiver, (C) build a deterministic 2-stream UL injection testbed to develop the receiver DSP independent of live dual-attach.

## rev-59 (2026-07-08): MU-MIMO root understood — nb_rx=1 = no spatial dim (user's "ring overlap" intuition); dual-attach = contention lottery (not steering)
User asked if the vrtsim channel model / ring-overlap is the issue. ANSWER = yes at the core. Full matrix (N=2 @273, 2-port):
- 1RX plain OFDMA: try1 storm 230 rnti 0/2; try2 CLEAN 2/2 (du_crnti=2). Attach WORKS at 1 antenna (RA/OFDMA separates in FREQUENCY).
- 1RX + MU features (cosched=same PRB): UE0 attaches, UE1 BURIED (du_crnti=1). Same-PRB @1 antenna = unseparable.
- 4RX + steering(auto): storms 503/445, 1 UE each (0 clean in 2 tries).
- 4RX no-steer: try1 storm 344 0/2; try2 CLEAN 2/2 (du_crnti=5). Dual attach achievable at 4RX too.
KEY FACTS:
1. Ring STORAGE does not overlap (UE0->UL stream0, UE1->UL stream1, sized total_ul_streams, correct). The overlap is the CHANNEL-MODEL COMBINE (vrtsim.c:1274-1313 SUMS both UE streams into the gNB antennas = models over-the-air superposition).
2. At nb_rx=1 (current du/ru conf default!) the sum is rank-1 -> SAME-PRB MU-MIMO IMPOSSIBLE IN PRINCIPLE (1 antenna can't separate 2 co-channel UEs; my VRTSIM_UL_MU_STEER is a NO-OP at 1 ant, w[u][0]=1). This is THE reason all Phase-4 receiver work can't succeed at 1 antenna. MUST set NB_ANT_RX>=2.
3. The RA STORM (100s of rntis) blocking dual attach is 2-UE simultaneous CONTENTION lottery, NOT my steering (4RX-no-steer stormed too) and NOT the channel model. Dual attach IS achievable (2/2 seen at 1RX-plain AND 4RX-nosteer) when the lottery cooperates. Hint: 4RX+steer stormed both tries vs 4RX-nosteer got clean -> steering may WORSEN attach (phase-ramp on PRACH) -> gate steering+cosched ON only AFTER both connected.
PLAN: nb_rx=4; attach both WITHOUT steering (OFDMA, retry lottery to 2/2); THEN enable steer+cosched+IRC for the same-PRB receiver test on a genuine rank-2 co-channel scenario. My earlier Phase-4 runs were all @nb_rx=1 = structurally hopeless for separation. Reboot NOT needed (repeatable, config-level). Box cleaned.

## rev-60 (2026-07-08): MILESTONE — clean 2/2 dual attach @4RX + genuine rank-2 co-channel reached; MMSE still outputs 0 (Stage-2)
Two attach-first gates (both default-off) killed the RA storm: (1) IRC MU-regime flag g_mu_mimo_active (MAC sets it only when trigger-latched AND >=2 connected AND no RA) — full-band Msg3 no longer trips IRC; (2) steering attach-first trigger (RU keeps rank-1 duplicate until /tmp/vrtsim_mu_steer_on touched by harness on ok==N_UE). Aligned cosched+IRC+steering to the SAME trigger (fixed chicken-and-egg: pre-PDU 2nd UE was cosched+IRC'd without steering -> unseparable -> never completed).
RESULT (NB_ANT_RX=4): du_crnti storm 100s -> 4-6; try2 CLEAN 2/2. [MU METRIC] now shows |chSelf|=194 |chPart|=139 (BOTH non-zero) = first genuine rank-2 co-channel two-UE same-PRB (rb 0+273) scenario the joint receiver has ever had. HUGE: prior Phase-4 was all nb_rx=1 (rank-1, hopeless).
OPEN (Stage-2 DSP): outAbsMean=0 llr=0 STILL -> mmse_2layers outputs zero. LIKELY CAUSE: steering never ACTIVATED in that run (steer_active=0). Without steering both UEs ~identical h -> chF2[0]~chF2[1] -> HxH singular -> MMSE zeroes. Confounder found: RU vrtsim LOG_I/LOG_A hidden at hw_log_level=warn -> can't SEE steer enable/activate (fixed: harness sets hw_log_level=info). Env-inheritance that carried OAI_UL_MU_* to DU works identically for VRTSIM_UL_MU_STEER to RU, so steering is ENABLED; question = did the trigger poll ACTIVATE it. Metric cap 10 (first-fire, pre-activation) -> changed to periodic %4000 sampling. NEXT: confirm steer ACTIVATED post-trigger; if MMSE still 0 with distinct channels = real Stage-2 scaling/extraction bug. Committed, gated off. Canonical: rev-60.

## rev-61 (2026-07-08): Stage-2 zero-output ROOT-CAUSED — OAI 2-layer funcs key off rel15_ul->nrOfLayers=1, not my passed layer count
Verified @4RX: clean 2/2 (1st try), steering ENABLED+ACTIVATED (RU log: UE0 w=[1,1,1,1], UE1 w=[1,j,-1,-j] DFT beam), genuine distinct co-channel. Yet mmse_2layers STILL outputs 0. Two concrete bugs found by reading the reused OAI funcs:
1. nr_ulsch_channel_compensation loops on `nrOfLayers = rel15_ul->nrOfLayers` (line 400/422), IGNORING the nb_layers param I pass. My two co-sched UEs each have nrOfLayers=1 -> only layer 0 compensated -> the PARTNER's compensated stream comp2[nb_rx_ant] is never produced (stays memset 0) -> 2-layer MMSE 2nd input = 0 -> degenerate -> zero output. (chPart!=0 is the channel ESTIMATE I extract separately; the COMPENSATED partner data is what's missing.)
2. It writes output at rxComp[layer][symbol*buffer_length]; my local comp2 is one-symbol sized read at offset 0 -> zeros for every symbol>0 (all my metric samples were sym>=1).
3. Also: for QPSK (Qm=2<=6) the normal 2-layer path uses nr_ulsch_compute_ML_llr, NOT mmse_2layers (mmse only for Qm>6=256QAM). I always call mmse_2layers.
ROOT: I'm stitching two separate 1-layer UEs (two pusch_pdus) into OAI functions built for ONE 2-layer UE (one pdu, nrOfLayers=2). They key off rel15_ul->nrOfLayers=1. FIX (Stage-2, real DSP): do the 2-layer compensation for the MU pair myself (matched-filter both chF2[0]/chF2[1] against rxFext at the correct symbol offset -> comp for both layers), then 2x2 MMSE (or ML for QPSK) -> separated self -> LLR. Not a param tweak; a proper joint-detector for 2x independent single-layer UEs. MILESTONE stands (attach/steering/co-channel all solved); this is the isolated remaining receiver math. Canonical: rev-61.

## rev-62 (2026-07-08): Stage-2 JOINT DETECTOR WORKS (non-zero output+LLR); new blocker = no co-scheduled UL traffic
Stage-2 fix applied+built: (1) temporarily present nrOfLayers=2 around nr_ulsch_channel_compensation so BOTH chF2[0]/chF2[1] get matched-filtered (was nrOfLayers=1 -> partner never compensated); (2) pass symbol=0 (it uses `symbol` only for output offset) -> compact offset-0 comp2buf (fixes symbol*bl OOB); (3) QPSK -> nr_ulsch_compute_ML_llr (interference-aware, uses rho), 256QAM -> mmse_2layers.
RESULT @4RX clean 2/2: [MU METRIC] outAbsMean 0->1408, llrAbsMean 0->19, llrMax 0->86 (was all-zero). Joint detector produces real separated output+soft bits. Both UEs (0489/f193) crc_valid on rb 0+273.
NEW BLOCKER (not the receiver): iperf_ue0/1.log both 0 BYTES -> essentially NO UL traffic. LCID4 RX ~55 bytes total. f193 got only 4 grants; ZERO same-slot co-scheduling (grep found no frame.slot with both rntis). So the two UEs never actually transmit same-PRB simultaneously -> IRC fired only ONCE -> can't prove separation under load or measure 2x. This is TRAFFIC GENERATION (iperf UDP not flowing / 2nd-UE CN routing / netns), orthogonal to the DSP.
ALSO: llrMax=86 is LOW (marginal post-separation SINR at 4 ant, DFT angles 0 vs 0.25). More antennas (NB_ANT_RX=8, angles 0 vs 0.125 = more orthogonal) should raise SINR/LLR -> robust co-sched decode. User authorized >4 ant.
NEXT: (a) get sustained simultaneous UL on both UEs (fix iperf / use flood-ping) so they co-schedule; (b) verify same-slot two-UE crc_valid + [MU METRIC] firing continuously; (c) NB_ANT_RX=8 for SINR margin; (d) measure aggregate LCID4 goodput -> target ~2x. DSP milestone DONE. Committed, gated off. Canonical: rev-62.

## rev-63 (2026-07-08): traffic fix built; UL data path traced to netns/tun; BLOCKED by box degradation (need reboot)
Step-1 (traffic) work: replaced iperf3 (needs reachable UPF TCP control -> 0-byte-log failure) with server-less UDP saturator ul_saturate.py (paced UDP, backlogs RLC, no server). Wired into run_multi_ue.sh + MU_DATAPATH_DIAG probe (tun tx_packets + route).
FINDING (from load run @4RX, 3x clean 2/2): saturator SENDS 300 MB/UE (sent=250033) but gNB LCID4 RX = ~110 bytes -> UL data NOT reaching the gNB. UEs get grants (08a2:28) but carry PADDING (empty RLC) -> ZERO same-slot co-scheduling -> IRC fires only 1x. So the co-channel load never materializes. Root not yet isolated: packets accepted at socket (route exists) but don't become UL air traffic; suspect netns route (10.0.0.1 not onto oaitun) OR UE tun-read->RLC. Datapath probe (tun tx_packets delta) INCONCLUSIVE because single-UE stopped attaching.
BLOCKER: box DEGRADED — single-UE now 0/1 attach, 177 synch-Failed (can't even lock SSB), RU raw_nz=0, load 5.5-7 (1/5min), uptime 3 days, HugePages leaked to 0-free (reclaimed). No runaway proc; load is decay from dozens of runs today. This is the documented bad-day (load shifts vrtsim PRACH/sync timing). NEED COLD REBOOT (user offered). 
RESUME AFTER REBOOT: (1) post_reboot_prep.sh; (2) confirm single-UE attach clean; (3) MU_DATAPATH_DIAG=1 N_UE=1 -> read tun tx_packets delta + route (isolate netns-route vs tun-read); (4) fix UL data path so both UEs backlog; (5) mu_load_verify.sh 4 -> confirm same-slot co-sched + IRC firing + both crc_valid; (6) NB_ANT_RX=8 if llrMax marginal; (7) measure aggregate LCID4 ~2x. Joint detector (rev-62) WORKS; only traffic+measurement remain. All committed. Canonical: rev-63.

## rev-64/65 (2026-07-08, POST-REBOOT): ALL MU-MIMO COMPONENTS VALIDATED; last-mile = multi-UE traffic path + reliable nb_rx>=2 attach
NOTE: post-reboot needs `echo 8192 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages` (reboot wipes to 0; post_reboot_prep.sh does NOT do it) THEN post_reboot_prep.sh.
- TRAFFIC (step1) VALIDATED single-UE nb_rx=1: ul_saturate.py 60 MB -> gNB LCID4 RX 61.5 MB (climbing, MCS 28); tun tx_packets delta 6252/3s = data DOES reach oaitun, netns route FINE. Measure UL via gNB LCID4 RX. The earlier "110 bytes" was box-degradation, not a data-path defect.
- scid BUG FOUND+FIXED (gNB_scheduler_ulsch.c ~2455): distinct DMRS was a NO-OP — gated behind unset OAI_UL_MU_DMRS AND clobbered by the default `pusch_pdu->scid=dmrs_info.scid` one line below. New block placed AFTER the default, gated on g_mu_mimo_active (trigger+both-attached), assigns nSCID by connection order. EFFECT: co-sched [MU METRIC] now |chSelf|=94 |chPart|=101 DISTINCT (were 192/192 EQUAL = singular MMSE). Correctness fix for joint channel estimation.
- HUGEPAGE-LEAK ROOT CAUSE: harness cleanup used `pkill -9 -x nr-oru`; a stray nr-oru escapes -x, keeps ALL 8192 hugepages mapped -> next run starves (Free=0) -> looks like "bad-day/degraded box". FIXED harness to `pkill -9 -f nr-oru`. ALSO: my MANUAL `sudo find /dev/hugepages -delete` is broken by the rtk hook rewriting it to `sudo rtk find` = "rtk: command not found" (rtk not in root PATH) -> use `sudo bash -c 'find ...'` or reset pool (echo 0 then 8192 > nr_hugepages). rtk ALSO breaks `cat >>` heredoc banks (rev-64/65 first attempts silently lost) -> bank via Edit tool.
- DEMONSTRATED @nb_rx=2 (run 223742, full stack): BOTH UEs attach (2 rntis, NO storm), steering ACTIVATED, joint detector fires (chSelf 94/chPart 101/outAbsMean 1527/llrMax 34), decodes crc_valid on rb 0+273.
REMAINING LAST-MILE (3 issues, all TESTBED-INTEGRATION, not receiver-DSP):
1. MULTI-UE UL TRAFFIC not reaching gNB: both saturators send 262 MB EACH but LCID4 ~165 bytes; grants carry padding (empty RLC); same-slot co-sched count=0 (empty-buffer UE never co-scheduled). Single-UE works (61MB) => multi-UE netns/tun-read specific. NEEDS: get a 2/2 attach + MU_DATAPATH_DIAG to read BOTH tun tx_packets (isolate UE1 netns-route vs tun-read->RLC).
2. nb_rx>=2 ATTACH ~50% LOTTERY: RA "no free space for a new detected rach"/"Error in scheduling rach" storms ~half the time (nb_rx=1 = 100% clean). NOT MU-features (plain nb_rx=2 also lottery). vrtsim multi-antenna RA/alignment. Suspect min_grant_prb=273 vs RAR/Msg3 placement at multi-antenna.
3. SINR MARGIN: nb_rx=2 llrMax=34 marginal (2x2 no diversity). NB_ANT_RX=4/8 for headroom (but #2 worse there).
RESUME: (a) retry to 2/2 + MU_DATAPATH_DIAG both tuns -> fix multi-UE traffic; (b) fix nb_rx>=2 RA reliability; (c) NB_ANT_RX=4/8 SINR -> measure aggregate LCID4 ~2x. Joint detector + traffic-gen + scid + gating ALL DONE & committed (bck fork through scid; oran_lab harness pkill-f + saturator). Canonical: rev-65.

## rev-67 (2026-07-09): TWO BIG FIXES — (1) sustained PRB reuse via per-UE sched; (2) THE gNB was rank-1 the whole time (pusch_AntennaPorts)
FIX 1 — PER-UE PRB SCHEDULING (sustained co-scheduling): the UL scheduler gate `B = estimated_ul_buffer - sched_ul_bytes == 0 -> skip` (gNB_scheduler_ulsch.c pf_ul) drops a UE from candidacy for several slots after a full-band grant goes in flight -> the two UEs SERIALIZE (take turns) -> same-slot overlap ~0-2. Fix: in MU regime, treat each connected UE as always-backlogged (bypass the B==0 skip; saturated = real buffer never empty) so BOTH enter UE_sched EVERY slot -> both full-band -> cosched overlaps. RESULT: real-reuse-slots (>=2 UE same PRBs/slot) 2 -> 4676 (nb_rx=1, 30s). Added [MU REUSE] counter (reliable; the ULSCH-trace SAME-SLOT metric reads 0 at nb_rx=1 because collisions trace-hide one UE). Committed 4d6b01a537.
FIX 2 — THE FUNDAMENTAL RANK-1 BUG: the gNB PUSCH RX antenna count = carrier_config.num_rx_ant = pusch_AntennaPorts (NR_MAC_gNB/config.c:679), NOT the `nb_rx` conf line. Harness patched nb_rx=2/4 but LEFT pusch_AntennaPorts=1 -> frame_parms->nb_antennas_rx=1 -> inner_rx nb_rx_ant=1 -> the joint receiver ran RANK-1 THE ENTIRE TIME (1 antenna cannot separate 2 co-channel UEs). EVERY prior "nb_rx=2/4" IRC test was degenerate (that's why llrMax was stuck ~34, chSelf~=chPart). Diagnosed via a [MU GATE] one-shot log (nb_rx_ant=1). FIX: harness now also patches pusch_AntennaPorts=NB_ANT_RX. VERIFIED: [MU GATE] nb_rx_ant=2, IRC fires with chSelf=260 chPart=192 (distinct rank-2), outAbsMean=2893, llrMax=167 (vs 34). Committed (harness).
NOW: with BOTH fixes (sustained co-sched + genuine 2 RX antennas), running the nb_rx=2 aggregate measurement. This is the first time the receiver has a REAL rank-2 co-channel every slot. Next: confirm both UEs crc_valid on co-scheduled slots -> aggregate LCID4 ~2x; then NB_ANT_RX=4 for margin. Canonical: rev-67.

## rev-68 (2026-07-09): both fixes PROVEN individually; last gap = multi-UE CONNECTION STABILITY at nb_rx_ant=2
Added [MU STATE] diag (g_mu/connected/any_ra/trig_latched per 2000 pf_ul calls) + [MU GATE] (nb_rx_ant). Focused nb_rx=2 run (try2 2/2):
- nb_rx_ant=2 CONFIRMED, decode HEALTHY (32 crc_valid @ SNR 41.8 dB — 2nd antenna does NOT hurt decode), IRC separation STRONG (llrMax 181, chSelf 206/chPart 192 distinct).
- BUT [MU STATE] shows connected=1 most of the time (rarely 2), 3 rntis + 1 RA-failed = CHURN. g_mu latched only BRIEFLY (IRC fired once) then dropped -> co-scheduling never sustained (REUSE empty) -> LCID4 165 bytes (grants carry padding, empty RLC because UEs keep dropping/re-RA).
DIAGNOSIS: the two fixes are each proven, but NOT together in one run because the two UEs don't STAY simultaneously connected at nb_rx_ant=2 (they churn). At nb_rx=1 they stayed stable (reuse=4676); at nb_rx_ant=2 they churn. Decode is healthy so it's not a 2-antenna decode failure; likely the vrtsim multi-UE stability wall (documented) aggravated, or an inactivity/scheduling interaction. NOT the receiver DSP.
OPERATIONAL: recurring hugepage leak (stray nr-oru not always caught even by pkill -f) keeps starving next-run launches -> must reset pool (echo 0/8192) between runs; this is the biggest time-sink. Harness cleanup + a pool-reset in preflight would help.
REMAINING: (1) multi-UE connection stability at nb_rx_ant=2 (keep both connected so g_mu stays latched); THEN sustained co-sched + IRC = both decode = aggregate ~2x is expected to follow (all pieces proven). (2) NB_ANT_RX=4 for SINR margin. State: two root-cause fixes done+committed (per-UE sched 4d6b01a537, pusch_AntennaPorts harness, scid, IRC nb_rx>=2, sustained-reuse counter). Canonical: rev-68.

## rev-69 (2026-07-09): THE separation blocker = IDENTICAL PILOTS + single-UE estimator (spatial-diversity/conditioning traced end-to-end)
Added [MU METRIC] corr2pct = per-RE avg 100*|<h0,h1>|^2/(|h0|^2|h1|^2) across the band (0=orthogonal, 100=collinear). @nb_rx_ant=2: corr2pct = 87-100 => the two co-scheduled UEs' channel ESTIMATES are ~collinear (rank-1) => IRC cannot separate, no matter the antennas/scheduling/math. This is THE reason same-PRB recovery fails.
ROOT traced end-to-end with [MU PILOT] (gNB scid) + [UE DMRS TX] (what the UE actually transmits): the gNB SETS distinct scid (UE0=0, UE1=1) and encodes it in DCI 0_1, BUT BOTH UEs transmit scid=0 with the IDENTICAL gold sequence (gold0 byte-identical) => identical DMRS => gNB estimates the SAME channel (h0+h1) for both => corr~100%. The DCI nSCID never reaches the UE (nr_ue_scheduler.c:628 reads dci->dmrs_sequence_initialization.val but it arrives 0; get_transformPrecoding resolves _disabled so nbits SHOULD be 1 — the loss is in encode/parse/format).
FIX ATTEMPT (OAI_UE_FORCE_SCID env, per-UE, gated DCI-0_1 + trigger file /tmp/vrtsim_mu_steer_on which is shared across netns): CONFIRMED applies ([UE FORCE SCID] applied scid=1) and corr dropped 100->87. But NOT enough: (a) some grants use DCI 0_0 (format 6) where scid stays 0 -> UE1 DMRS alternates; (b) DEEPER — even when aligned (UE1 tx scid=1, gNB estimates scid=1) corr stays ~87 because OAI's UL channel estimator is SINGLE-UE: it estimates each UE from the shared DMRS REs WITHOUT rejecting the other UE's overlapping pilot (no MU cross-cancellation), so nSCID quasi-orthogonality isn't exploited.
CONCLUSION: same-PRB MU-MIMO in this OAI needs GENUINELY orthogonal, estimator-separable pilots: FD-OCC DMRS PORTS (port0 [+1,+1] / port1 [+1,-1] — the estimator de-spreads => MU-aware) OR a custom joint MU channel estimator. nSCID + single-UE estimator = insufficient. Everything else PROVEN: sustained co-sched (per-UE sched, reuse 4676), 2 real RX antennas (pusch_AntennaPorts fix), IRC 2-layer math, steering orthogonal true-channels. The ONLY missing piece = separable pilots. NEXT: (1) force all co-sched grants to DCI 0_1; (2) try FD-OCC ports (revisit the OAI port>0 estimation path, distinct from the decode issue); (3) or joint MU estimator. Diagnostics [MU PILOT]/[UE DMRS TX]/[UE FORCE SCID]/corr2pct all committed. Canonical: rev-69.

## rev-70 (2026-07-09): STAGE-1 GENIE PROVES RECEIVER + THE REAL "BLOCK-1" = DU SEGFAULT IN THE IRC PARTNER SCAN (fixed)
STAGE-1 GENIE (OAI_UL_MU_GENIE env, inject known orthogonal DFT beams scaled to band-mean |chFext|): corr2pct=0, outAbsMean=3380-3578, llrMax 185-262 => RECEIVER DSP FULLY PROVEN with distinct channels. Pilots confirmed as the separation gap. (Genie v1 lesson: per-RE amplitude gave chSelf=22/llr~0 — must scale to band-mean.)
THE REAL "BLOCK-1" FOUND: du.log ends MID-LINE right after the first [MU METRIC] in EVERY MU run; dmesg: Tpool segfault at 0 (same IP, multiple runs). The IRC partner scan dereferenced gNB->ulsch[id].harq_process->ulsch_pdu UNGUARDED over all 144 slots; harq_process is NULL for unused slots. First IRC symbol finds the partner early (break before NULLs) -> metric prints -> later slot mismatches -> scan walks into NULL -> DU DIES. The whole "connection churn / UE drops when co-scheduling engages / g_mu won't sustain" story was the DU CRASHING — not UEs dropping, not steering transients, not decode failures. FIX: guard !active||harq_process==NULL + require partner scheduled the SAME frame/slot (also properly kills stale-partner mispairing = the old rev-58 partner-energy guard band-aid). Committed 84329f5677.
ALSO: VRTSIM_UL_MU_STEER_BOOT (steering active from boot, no attach-first trigger): 2/2 attach on try1 => boot steering does NOT break PRACH at 2RX; eliminates the activation transient entirely (steady-state DMRS/PUSCH steering consistency verified by code: one constant time-domain weight per (UE,antenna) applied to every sample — DMRS and data always see the same channel; the only mismatch window was the mid-run activation flip, now gone).
NOW RUNNING: boot-steer + genie + crash fix, 60s load. Expect: DU survives, IRC fires continuously, sustained REUSE, both UEs decode co-channel via genie -> aggregate. Then Stage-2 pilots for the real (non-genie) result. Canonical: rev-70.

## rev-71 (2026-07-09): ★★★ SAME-PRB MU-MIMO RUNS END-TO-END (genie) — both UEs decode simultaneously on shared PRBs, sustained
SECOND DU-killer found+fixed en route: the Stage-2 nrOfLayers=1->2->restore hack MUTATED THE SHARED PDU; per-symbol Tpool workers run in parallel -> another symbol's worker read the transient nrOfLayers==2 in the caller's layer-demap (nr_ulsch_demodulation.c:1497, via addr2line on the dmesg IP) -> indexed llrss[1]==NULL for a 1-layer UE -> segfault at 0. FIX: LOCAL pdu copy with nrOfLayers=2 (3af11b2ba7). Together with the partner-scan NULL guard (84329f5677) = "Block-1" fully dead.
RESULT (run 213039: nb_rx=2 + STEER_BOOT + genie + both saturating 60s, try1 2/2): NO crash (dmesg clean), IRC ran CONTINUOUSLY (~88k invocations), REUSE=7424 same-slot co-scheduled slots, corr2pct=0 llrMax 230-257 throughout, **UE 8111 = 4.57 MB and UE f82b = 4.56 MB LCID4 — BOTH UEs delivering simultaneously on the SAME PRBs, aggregate 8.7 MB climbing linearly, perfectly balanced 50/50**. First sustained end-to-end same-PRB MU-MIMO operation on this testbed.
CAVEATS/NEXT: (1) aggregate rate ~3.5 Mbps sim is LOW vs single-UE OFDMA (~16 Mbps sim) — likely MCS held low (SNR estimator sees the co-channel interference pre-IRC) + HARQ; quantify vs baselines (single-UE and 2-UE OFDMA) and chase MCS. (2) This is GENIE-assisted (known channels); Stage-2 separable pilots (FD-OCC ports) still needed for the real result. (3) trace-level crc for f82b showed fails while its LCID4 flowed — trace lines are throttled samples, LCID4 is ground truth. Canonical: rev-71.

## rev-72 (2026-07-09): ★★★★★ REAL (NO-GENIE) SAME-PRB MU-MIMO WORKS — FD-OCC ports, corr=0 on real estimates, MCS 14, 66 MB aggregate
THROUGHPUT ROOT-CAUSE (user's question "is MMSE-IRC weak -> MCS low"): postSINR (EVM on separated QPSK output) is BIMODAL under genie — ~35 dB (clean, IRC works) vs 5.9 dB cluster = GENIE ARTIFACT (flat injected channel ignores per-RE phase rotation from timing offset TAest 3-6 samples ≈ 5 rotations across 273 PRB) -> those symbols poison TBs -> abort (dtx=0) -> BLER-MCS pins MCS 0 despite reported SNR 41.8. IRC math fine; flat genie was the limiter. Reported-SNR high = estimator NOT the issue.
STAGE-2 (FD-OCC DMRS PORTS) LANDED: both ends already had port support (UE TX get_Wf/Wt; gNB nr_dmrs_rx wf/wt de-spread) — only WIRING was missing (UE hardcodes dmrs_ports=1 and ignores DCI antenna_ports, same one-sided confound as nSCID; the old "OAI can't decode port>0" = gNB-only port with UE still on port0). Fix: gNB OAI_UL_MU_PORTS (co-sched UE0->port0/UE1->port1 by connection order) + UE OAI_UE_FORCE_DMRS_PORT (gated DCI 0_1 + trigger) + harness mode-conditional envs. GATE LESSON: both sides must latch the SAME sticky trigger (first run: gNB gated on dynamic g_mu -> transient -> gNB est port0 vs UE tx port1 -> OCC mismatch -> estimate ~0 (log2h=0) -> collapse; fixed sticky).
RESULT (run try1 2/2, nb_rx=2, STEER_BOOT, 60s, NO genie NO scid): corr2pct=0 ON REAL ESTIMATES, postSINR 23->35->41.3 dB (better than genie: real estimates absorb timing rotation), REUSE=9918, **MCS 0->14-15 BOTH UEs, LCID4 38.7 + 27.4 = 66.1 MB AGGREGATE on the SAME PRBs** (7x the genie run; ≈ single-UE baseline on shared spectrum). GENUINE UL MU-MIMO: FD-OCC pilots -> per-port estimates -> MMSE-IRC -> both decode.
REMAINING: (a) tail-end samples show a collapse (postSINR -27, log2h=0) near run end — teardown vs real transient, check; (b) MCS 14 not 28 — BLER ramp needs longer run or the residual dips cap it; (c) proper A/B vs single-UE same-window for the official 2x figure; (d) NB_ANT_RX=4 margin. Canonical: rev-72.

## rev-73 (2026-07-10): STANDARD 5G DCI PORT SIGNALING IMPLEMENTED + PROVEN; env forces retired
User pushed for standard 5G (UE follows DCI) over env hacks — correct call. INVESTIGATION: (1) antenna_ports was NEVER IMPLEMENTED for UL: gNB hardcoded val=0 (gNB_scheduler_primitives.c:1252), UE extracted but never USED it (dmrs_ports=1 hardcoded, nr_ue_scheduler.c:397). (2) Implemented both ends per 38.212 T7.3.1.1.2-8: gNB val=2*(cdm-1)+port from pdu; UE port=val&1, cdm=(val>>1)+1. (3) "gNB nbits=0" scare was a FALSE READING (my [DCI TX] log at the config_uldci fill site runs BEFORE nr_dci_size populates nbits inside fill_dci_pdu_rel15). [DCI PACK] log at the pack site = authoritative: gNB nbits=3/1, UE nbits=3/1 — SIZES MATCH, channel fine. The historical "UE rx scid=0" mysteries dissolve accordingly.
FIX 2: gNB [MU PORT] must assign port1 ONLY on DCI 0_1 grants (0_0 has no antenna-ports field; UE correctly defaults port0 on 0_0 -> pdu stamping port1 on 0_0 grants caused OCC mismatch poisoning BOTH UEs -> corr=99 samples, MCS 0/5). Gated on current_UL_BWP.dci_format==0_1.
RESULT (standard path, no forces): [DCI PACK] nbits=3/1 -> UE1 rx val=1 -> tx port1; MCS UE0=15 UE1=13-14; 15.8+12.5=28.3 MB. Per-grant atomic consistency achieved the STANDARD way; MU_UE_FORCE env demoted to opt-in.
RESIDUAL: phantom samples (log2h=0, -21..-25 dB) persist even with consistent ports -> NOT pilot mismatch; suspect missed PDCCH / skipped PUSCH on always-granted slots (UE granted every slot doesn't always tx). Aggregate 28 MB < sticky-run 66 MB — the phantoms + BLER coupling still cap. NEXT: rnti-tag the phantom metric samples + count dtx-vs-abort per rnti; check UE-side PDCCH miss stats; then MCS-28 ramp + official 2x A/B + NB_ANT_RX=4. Canonical: rev-73.

## rev-66 (2026-07-08): PRB REUSE RESOLVED — it WORKS; the blocker was IRC degenerate at 1 antenna
Systematic isolation on the CLEAN box (retry-to-2/2 harnesses in oran_lab: mu_datapath_probe / mu_prbreuse_probe / mu_cosched_only / mu_noscid / mu_nocosched). Findings:
- MULTI-UE TRAFFIC PATH WORKS: N_UE=2 nb_rx=1 pure OFDMA (no MU env) -> BOTH tun tx_packets delta ~6252 AND gNB LCID4 = 32 MB + 81 MB = ~113 MB. Both UEs deliver UL. The earlier "165 bytes" was box-degradation + IRC (below), NOT a traffic defect.
- PRB REUSE HAPPENS: cosched-ONLY (no IRC/scid/steer) nb_rx=1 -> [MU COSCHED] both rntis SAME slot, SAME-SLOT co-sched count > 0 (=2), BOTH UEs deliver (5.6 + 33.6 MB). The co-schedule mechanism (free UE0 PRBs -> UE1 reuses same rbStart=0/273) is CONFIRMED WORKING.
- ROOT CAUSE of "everything broken with MU features" = IRC RUNS THE 2-LAYER JOINT DETECTOR ON A RANK-1 (1-antenna) SIGNAL -> degenerate -> corrupts EVERY decode (grants carry garbage, both UEs starve to ~165 bytes). Isolated by elimination: no-scid still broken, no-cosched still broken, cosched-ONLY (no IRC) WORKS. FIX: gate IRC on nb_rx_ant>=2 (committed a9d136e9d0). At 1 antenna 2 co-channel UEs simply collide; IRC cannot help.
- @nb_rx=2 with the IRC>=2 gate: both UEs deliver data again (1.18 + 3.99 MB), IRC metric healthy (earlier sample llrMax=217 vs 34). 
SO: PRB reuse is NOT blocked — traffic works, co-schedule works, both deliver. REMAINING for a strong 2x demo: (1) nb_rx>=2 attach = 2-UE lottery ~50% (vrtsim multi-UE wall, any antenna count; single-UE=100%); (2) SAME-SLOT overlap is LOW/sporadic (0-2 slots) — the UL scheduler mostly ALTERNATES UEs rather than overlapping every slot; cosched frees PRBs but doesn't FORCE both into every slot (scheduler picks ~1 UE/slot) -> need to make co-scheduling SUSTAINED (schedule both every UL slot); (3) then IRC separates the overlapped slots at nb_rx>=2, measure aggregate ~2x. Canonical: rev-66.
