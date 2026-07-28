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
