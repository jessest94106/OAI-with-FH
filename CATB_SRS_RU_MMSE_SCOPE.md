# Cat-B split: MMSE in RU, chest + BF weights in DU, SRS on — SCOPE
Branch `catb-srs-ru-mmse` (from `fh-latency-experiment` @8694c52), 2026-07-27.
**Goal: measure how fronthaul latency degrades the beamforming control loop.**

## What changes

| | today (Cat-A) | target (Cat-B-like) |
|---|---|---|
| FH UL payload | 16 antenna streams of IQ | N_layer combined streams |
| Spatial combining | DU L1 (MRC / MMSE-IRC from DMRS) | **RU** applies weights |
| Channel estimation | DU, per-slot, from PUSCH DMRS | **DU**, from **SRS** |
| Weight computation | DU (implicit, per slot) | **DU**, delivered to RU over FH |
| Channel knowledge | DMRS only (`do_SRS=0`) | SRS sounding |

The loop being studied:
```
UE SRS -> RU packetise -> FH up (Ta4) -> DU chest -> DU weight calc
       -> FH down (C-plane BFW, T1a) -> RU applies W -> PUSCH combined -> DU decode
```
Weights are always stale by `T_loop`. Performance falls when `T_loop` approaches the
channel coherence time `T_c ~= 0.423 / f_D`, `f_D = v*fc/c`.
At 3.5 GHz: 3 km/h -> T_c 43 ms | 30 km/h -> 4.3 ms | 120 km/h -> 1.1 ms.

## THE CRITICAL DESIGN POINT — latency must be injected in SIM time

TS=0.02 dilates wall time 50x. A real 100 us FH latency is **2 us of sim time** — i.e.
essentially zero to the radio. Wall-clock FH delay therefore CANNOT represent real loop
latency, exactly as wall bandwidth could not represent real FH capacity (25 Gb/s real =
500 Mbps wall). **Inject the loop delay as an integer number of slots/symbols**
(`VRTSIM_BFW_DELAY_SLOTS`), and quote results in sim-ms against coherence time.
Getting this wrong makes every number meaningless — it is the same class of error as the
TDD-duty and 60 s-OLLA traps already in the ledger.

## EXISTING Cat-B CODE — already on this branch (checked 2026-07-27)

`e390c16356` (Jesse, 2026-07-08, ported from `duranta-project/oru_new_beamforming ebb57947`)
is an ancestor of HEAD on `compression-plus-timing-fix`. It adds **DL codebook Cat-B**:

- `executables/nr-oru.h:29-41` — `oru_codebook_t { nb_fh_streams, nb_beams,
  c16_t w[64 beams][8 txru][8 streams] }`, held in `ORU_t`.
- `executables/nr-oru.c:600` — `apply_codebook_weights()`:
  `tx_out[txru][re] = SUM_s W[beam][txru][s] * fh_in[s][re]`, Q15 complex MAC.
- Wired into `oru_north_read_thread` (DU->RU, TX path). `nb_fh_streams==0` => passthrough,
  the default. Beam selected by C-plane `beam_id`.

**What this buys us** (P3/P4 are extensions, not greenfield):
- the Q15 complex MAC kernel — identical math, transposed dimensions;
- the dual-buffer pattern (logical FH streams vs physical antennas) with clean
  passthrough when disabled — reuse the same env-gated-off-by-default discipline;
- config plumbing for weights living in `ORU_t`.

**What it does NOT cover — the real work:**
| | existing | needed |
|---|---|---|
| direction | DL / TX (`north_read`, precode streams -> antennas) | **UL / RX** (combine 16 antennas -> layers, south path) |
| weight source | static 64-entry codebook, picked by `beam_id` | **explicit MMSE weights** computed per update in the DU |
| frequency granularity | one weight set per symbol | **per-PRB / per-RBG** (MMSE weights are frequency-selective) |
| size limits | `MAX_NB_TX 8`, `MAX_STREAMS 8` | 16 RX antennas => raise; weight store becomes 106 PRB x 16 x 2 = 13.6 kB per update, not 64 beams |

RU apply cost for UL: `nb_rx x nb_layers` MACs per RE = 32/RE at 16x2, x1272 RE x 14 sym
per slot in scalar Q15 — real but bounded; must be measured against the RU budget (P4 gate c).

## Phases (each with its own gate; stop if a gate fails)

**P0 — instrument before changing anything.** RU-side timing/quality counters
(per-slot combine time, weight age in slots), and a Cat-A reference at 106 PRB w9:
throughput, MCS, per-antenna preSNR, PRACH. *Gate: reference reproduces 177.8 Mbps
@MCS 28/28.* Rationale: moving MMSE into the RU removes the DU-side instrumented
receiver that every previous diagnosis depended on — replace it first, not after.

**P1 — enable SRS end to end.** Known multi-part integration (tested 2026-07-14:
`do_SRS=1` alone runs but produces ZERO measurements): fhi_72 `srsEnable`/`srsEnableCp`,
SRS eAxC config, SRS extract/deposit path in `oaioran.c` (mirror the PRACH path), plus
vrtsim RU handling. *Gate: DU logs non-zero SRS channel estimates for both UEs.*
This is the largest single chunk and the most likely place to stall.

**P2 — DU computes weights from SRS, logs them, does NOT apply them.** Compare against
the existing DMRS-derived MMSE-IRC weights. *Gate: SRS-derived and DMRS-derived weights
agree within ~1 dB of combined SINR on a static channel.* Cheap way to validate the
estimator before any architecture change.

**P3 — weight delivery path DU->RU in vrtsim, with `VRTSIM_BFW_DELAY_SLOTS`.**
Implement in vrtsim (our own shim), NOT in fhi_72/xran — the real Cat-B C-plane BFW
path is a far larger job and is not needed to answer the latency question.
*Gate: with delay=0 and weights applied at the RU, throughput matches Cat-A parity.*

**P4 — move MMSE to the RU; FH carries layers, not antennas.** Apply W at the
`ul_combine_buffer` merge point (`vrtsim.c:262/825`). *Gates:* (a) throughput parity at
delay 0; (b) measured FH load drops from 142 Mbps to ~18 Mbps at 106/w9 (2 layers vs 16
antennas) plus SRS and BFW overhead; (c) **RU stays inside its real-time budget** — 16x16
MMSE per RB-group per slot is heavy, and RU overrun is the confound that has already
produced two false diagnoses in this lab.

**P5 — THE EXPERIMENT.** Sweep `T_loop` (slots) x UE speed (km/h). Per point: aggregate
throughput (180 s, converged — 60 s reads ~1/3), MCS, TBLER, and weight age. Output: the
degradation surface and the maximum tolerable loop latency per speed. Predict
degradation once `T_loop > ~0.1 * T_c`.

**P6 — FH cost of the loop.** BFW volume = `N_ant x N_layer x N_RBG x 4 B` per update;
sweep update rate against throughput to find the knee. Cat-B's UL saving is real only if
BFW traffic stays small.

## Risks / cons

- **SRS integration (P1) may dominate the effort.** Fallback that still answers the
  question: compute weights from **DMRS** (already available) and inject the same
  artificial delay. This isolates the latency loop from the SRS work and could be run
  first as a cheap pilot. Recommended if P1 stalls more than ~2 sessions.
- **Loss of DU-side instrumentation** once combining moves to the RU — mitigated by P0.
- **RU real-time overrun** masquerading as latency degradation. 106 PRB has ~2x headroom
  (61.44 Msps) which is why the whole plan sits at 106; instrument and check per phase.
- **OLLA confound**: stale weights lower SINR, OLLA then lowers MCS. Report weight age
  and SINR alongside throughput so cause and effect stay separable.
- **Not real Cat-B on the wire.** We emulate the split inside vrtsim; the O-RAN C-plane
  section-extension BFW encoding is out of scope. State this in any writeup — the
  latency physics is faithful, the protocol encoding is not.
- 1-TX UEs mean SRS gives a per-UE 16x1 channel vector — sufficient for UL combining,
  but no UL codebook/TPMI work is possible.

## Out of scope
Real C-plane BFW encoding; DL beamforming; Cat-B at 189/273 PRB (RU headroom);
antenna-switching or non-codebook SRS usage; MU pairing driven by SRS (separate study,
see [[oran-phy-arch]] — measured up to 12x potential).
