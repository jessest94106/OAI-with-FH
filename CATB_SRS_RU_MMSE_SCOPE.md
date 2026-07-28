# Cat-B UL: MMSE in RU, chest + weights in DU — SCOPE (rev 2)
Branch `catb-srs-ru-mmse`, 2026-07-27. Supersedes rev 1 (rewritten after finding the
existing Cat-B DL port and the reference-symbol constraint below).

## The question
**How much does fronthaul latency in the beamforming weight loop cost, and what is the
maximum tolerable loop delay as a function of UE speed?**

Success = a degradation surface (throughput / SINR vs loop delay x speed) plus a stated
tolerable-latency bound. Everything else in this plan exists only to make that measurable.

## The constraint that shapes everything

Once the RU combines 16 antennas into 2 layers, **the DU can no longer estimate the
channel** — it never sees per-antenna data again. So the DU needs an *uncombined
reference*. Three ways, and this choice is the plan's main fork:

| reference | FH cost/UL slot vs Cat-A | standard? | notes |
|---|---|---|---|
| (a) **SRS on its own eAxC** | 12.5% (+ SRS bursts) | **yes** — how real Cat-B does it | needs full SRS enablement |
| (b) **DMRS symbols forwarded per-antenna** | 31% (3 of 14 sym at 16 ant, rest at 2 layers) | no — invented flow | cheap, works inside vrtsim today |
| (c) RU computes its own weights | best | n/a | **rejected — user wants weights in the DU** |

(b) is not standards-conformant (eAxC count would vary by symbol), but it is legal inside
vrtsim, which is our own shim. It de-risks the physics cheaply. (a) is the real answer.

## Two tracks

**Track A — the physics, using (b). This is the critical path.**
Answers the question with no SRS work at all. Weights come from DMRS the DU already uses
for MMSE-IRC today; the loop is created artificially by applying slot-N weights to slot
N+d. Loop delay `d` is the independent variable.

**Track B — standards fidelity, using (a).** Swap the weight source to SRS. Adds a second
staleness term (sounding period on top of loop delay), which is what a real deployment
actually experiences. Run only after Track A produces a curve.

## LATENCY MUST BE INJECTED IN SIM TIME — the trap to avoid

TS=0.02 dilates wall time 50x, so a real 100 us FH latency is **2 us of sim time**:
invisible to the radio. Wall-clock delay cannot represent loop latency, exactly as wall
bandwidth could not represent FH capacity (25 Gb/s real = 500 Mbps wall). Inject the delay
as an integer number of **slots** (`VRTSIM_BFW_DELAY_SLOTS`) and quote results in sim-ms
against coherence time. Same error class as the TDD-duty and 60 s-OLLA traps already in
the ledger; getting it wrong makes every number meaningless.

Coherence time at 3.5 GHz (`T_c ~= 0.423/f_D`): 3 km/h -> 43 ms | 30 -> 4.3 ms | 120 -> 1.1 ms.
At 30 kHz SCS one slot = 0.5 ms sim, so d=1..64 slots spans 0.5-32 ms — brackets all three.

## What already exists (do not rebuild)

`e390c16356` (2026-07-08, from `duranta-project/oru_new_beamforming`), ancestor of the OAI
tree HEAD on `compression-plus-timing-fix`:
- `nr-oru.h:29` `oru_codebook_t { nb_fh_streams, nb_beams, c16_t w[64][8][8] }` in `ORU_t`
- `nr-oru.c:600` `apply_codebook_weights()` — Q15 complex MAC, `out[txru] = SUM_s W[s]*in[s]`
- wired into `oru_north_read_thread`; `nb_fh_streams==0` => passthrough (default off)

Reusable: the Q15 MAC kernel, the logical-streams-vs-physical-antennas dual-buffer pattern
with clean passthrough, weights-in-`ORU_t` plumbing, and the env-gated-off discipline.
Not covered: it is **DL/TX**, **static codebook by `beam_id`**, **one weight set per symbol**,
`MAX_NB_TX 8`. UL needs the RX path, explicit per-PRB weights, a delivery path, and 16 antennas.

## Track A phases

**A0 — instrument the RU first.** Per-slot combine time, weight age (slots), and an RU-side
SINR proxy. *Gate: Cat-A reference at 106/w9 reproduces 177.8 Mbps @ MCS 28/28 with the new
counters live.* Moving combining into the RU deletes the DU-side instrumented receiver that
every past diagnosis in this lab relied on — replace it before removing it, not after.

**A1 — per-antenna DMRS passthrough in vrtsim.** Data symbols still combined by the DU as
today; only the plumbing changes so DMRS symbols stay per-antenna. *Gate: bit-identical
throughput to A0 (this phase must be a no-op functionally).*

**A2 — DU exports weights; RU applies them; delay knob.** Extend the existing kernel to the
UL path with explicit per-PRB weights and `VRTSIM_BFW_DELAY_SLOTS`. *Gates:* (a) d=0 matches
A0 within 1%; (b) RU stays inside its real-time budget — 16x2 MACs/RE x 1272 RE x 14 sym per
slot in scalar Q15; (c) measured FH load drops to ~31% of Cat-A.

**A3 — THE EXPERIMENT.** Sweep `d` = 0,1,2,4,8,16,32,64 slots x speed = 0,3,30,120 km/h.
Per point: 180 s converged throughput, MCS, TBLER, weight age, per-layer SINR.
N>=2 wherever the curve bends. Predict degradation onset near `d ~ 0.1 x T_c`.

## Track B phases (after A3)

**B1 — enable SRS end to end.** fhi_72 `srsEnable`/`srsEnableCp`, SRS eAxC config, extract/
deposit path in `oaioran.c` mirroring PRACH, vrtsim RU handling. *Gate: non-zero SRS channel
estimates at the DU for both UEs.* Known state: `do_SRS=1` alone runs but yields zero
measurements (tested 2026-07-14).

**B2 — weights from SRS instead of DMRS.** *Gate: SRS- and DMRS-derived weights agree within
~1 dB combined SINR on a static channel.*

**B3 — repeat A3's sweep with sounding period as a second axis.** Deliverable: does periodic
sounding change the tolerable-latency bound versus continuous DMRS-derived weights?

## Risks / cons

- **Track A's flow is non-standard** (per-symbol eAxC change). Fine inside vrtsim, must be
  stated in any writeup: the latency physics is faithful, the protocol encoding is not.
- **RU real-time overrun masquerading as latency degradation** — the confound that produced
  two false diagnoses here. Whole plan sits at 106 PRB (~2x headroom); gate A2(b) checks it.
- **OLLA confound**: stale weights lower SINR, OLLA then lowers MCS, throughput falls for a
  second reason. Report weight age and SINR beside throughput so cause stays separable.
- **B1 may dominate effort.** That is exactly why it is Track B — the question is already
  answered by then, and B only upgrades fidelity.
- **1-TX UEs**: SRS gives a 16x1 channel vector per UE. Enough for UL combining; no UL
  codebook/TPMI work possible.
- **MU interaction**: 2 co-scheduled UEs share PRBs, so weights are joint MMSE-IRC, not
  per-UE MRC. Stale weights hurt separation faster than they hurt SU gain — expect the
  MU case to degrade first, and keep an SU control arm.

## Out of scope
Real C-plane BFW section-extension encoding; DL beamforming (the existing port already does
codebook DL); Cat-B at 189/273 PRB; antenna-switching / non-codebook SRS usage; SRS-driven
MU pairing (separate study, see [[oran-phy-arch]], measured up to 12x potential).
