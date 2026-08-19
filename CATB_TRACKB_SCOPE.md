# Track B — standards-conformant Cat-B (SRS-referenced) — SCOPE

2026-08-19. Companion to `CATB_ORU_SRS_SCOPE.md` (the O-RU SRS forwarding job, which is Track B's
prerequisite) and `CATB_SRS_RU_MMSE_SCOPE.md` (which named this option (a) — *"the real answer"*).

## 1. What Track B is

**Weights from SRS. The RU beamforms the ENTIRE PUSCH — data and DMRS. The DU MEASURES the
effective channel instead of reconstructing it.**

That single change is the whole of Track B. Everything below follows from it.

## 2. Delta from Track A (what we run today)

| | Track A (current) | Track B |
|---|---|---|
| weight reference | PUSCH DMRS | **SRS, own eAxC** |
| DMRS forwarded per-antenna? | **yes, all 16** | **no** |
| RU combines | data symbols only | **whole PUSCH** |
| DU obtains `h_eff` by | **reconstructing** `sum_a w_a H_a` | **measuring** the beamformed DMRS |
| UL eAxC in a PUSCH slot | 16 | **n_layers (1-2)** |
| FH load vs Cat-A | ~35% | **12.5%** + periodic SRS bursts |
| standards-conformant | no — "invented flow", eAxC count varies by symbol | **yes** |
| dominant staleness | FH loop delay (1-2 slots) | **sounding period (20-80 ms)** |

## 3. Why it removes the entire current bug class

Every open Cat-B defect is a cost of **reconstruction**:
- conjugation convention (`W = G^-1 H^H` already carries the conjugate)
- weight vintage / applied-record keying per slot
- per-antenna estimate staleness
- **the live blocker**: on data symbols `H_1..15` are 15 identical noise values, so
  `h_eff = w_0 H_0 + H_c * sum(w_1..15)` and `sum w ~ 0` for a beamformer -> collapses to 0.019

**Track B has none of these**, because the DU never computes `sum_a w_a H_a`. It runs ordinary
channel estimation on the beamformed DMRS it receives. The effective channel is whatever arrives.

## 4. Work items

**Prerequisite: `CATB_ORU_SRS_SCOPE.md` W1-W5 must be done first** (O-RU SRS forwarding, and in
particular W3 — verify the DU RX routes the SRS eAxC into `rxdataF`). Track B cannot start
without it.

### B1 — Weight computation moves to the SRS channel
`nr_ulsch_demodulation.c`'s weight production currently runs on PUSCH reference symbols gated on
`!catb_comb && catb_dmrs_sym && nb_rx_ant == nb_rx_ant_true`, with a partner scan over co-scheduled
UEs. Replace the input with the SRS-derived channel from `nr_srs_channel_estimation()`.
Keep the MMSE solve (`G = H^H H + nvar I`, `W = G^-1 H^H`) — it is unchanged and already correct.

### B2 — RU: combine ALL PUSCH symbols, not just data
`oaioran_ru.c` currently skips DMRS via the shm ring's `dmrs_mask` (the RU decides on weight
presence; the DU withholds BFW on DMRS symbols). In Track B the DU attaches BFW to every PUSCH
symbol. **`dmrs_mask` becomes unnecessary — delete that path, do not leave it dual-mode**; a
half-combined slot is the documented partial-TB killer.

### B3 — DU: delete the `h_eff` reconstruction
Remove the `catb_comb` branch that builds `chFext[l][0] = sum_a w_a H_a`. Instead let the normal
channel-estimation path run on the received beamformed stream with `nb_rx_ant = n_layers`.
`catb_applied_write/read` and the `applied[]` table in `catb_weight_ring.h` become dead — the DU no
longer needs to know which vector the RU applied. **This is a net DELETION of the most bug-prone
code in the project.**

### B4 — eAxC / antenna-count reconfiguration
UL eAxC count in a PUSCH slot drops from 16 to `n_layers`. Touches `oran-config.c` UL endpoint
setup and the DU's `nb_antennas_rx` for the UL path. **Highest-risk item** — the 16-RX assumption
is wired through `MAX_ANT`, scratch buffers and `defs_gNB.h` (see `COMMIT_PLAN_UNCOMMITTED_TREE.md`
for what the 16-RX enablement touched).

### B5 — SRS periodicity as a swept parameter
Expose the sounding period (20/40/80 ms) as a knob. This is Track B's independent variable.
**Add it to the `run_du.sh` allowlist** — unlisted variables are dropped SILENTLY (has bitten 3x).

## 5. What Track B MEASURES — a different experiment, not a better Track A

Track A's deliverable is *throughput vs FH weight-loop delay*. Track B **cannot** produce it: at a
20 ms sounding period the channel estimate is already 40 slots old, so sweeping FH delay 1->4 slots
moves total staleness 41->44 (7%) — buried by the ~2x run-to-run variance measured on this rig.

**Track B's natural deliverable instead:**

> throughput / SINR vs **sounding period** x **UE speed**, i.e. how fast can the channel age before
> SRS-based Cat-B beamforming stops paying — and what sounding period a given mobility requires.

That is the question an operator actually asks, and it is standards-conformant. It also reuses the
existing mobility harness (`VRTSIM_UE_SPEED_KMH`, CDL channels) unchanged.

**Both tracks together give the full picture:** Track A isolates the FH-latency term, Track B gives
the operating envelope. Neither subsumes the other.

## 6. What Track B delivers that Track A cannot

1. **The 87.5% FH reduction figure.** Track A only reaches ~65% off, because DMRS still goes out on
   all 16 antennas. **If the 87.5% number is a project deliverable, it requires Track B.**
2. **Standards conformance.** Track A's flow is explicitly non-conformant (eAxC count varies by
   symbol). Any external claim about "O-RAN 7.2 Cat-B" should rest on Track B.
3. **The §9 C-plane congestion prediction becomes testable in a realistic configuration** — BFW on
   every PUSCH symbol at a 250 us delivery window, against a fronthaul at its cap.

## 7. Acceptance

1. `rx_srs_packets` non-zero; `nr_get_srs_signal() >= 0`; `handle_nr_srs_measurements()` fires.
2. SRS-derived per-antenna `|H_a|` matches the PUSCH-DMRS-derived one to within noise
   (reuse the `[CATB HSUM]` probe).
3. UL eAxC count in a PUSCH slot == `n_layers`; FH load measured at **12.5%** of Cat-A.
4. Throughput within a stated margin of the Cat-A baseline at low UE speed
   (2-UE: ~174 Mbps / MCS 28,28; single-UE: 43.95 Mbps / MCS 18).
5. Cat-A control unregressed with all Track B knobs OFF.
6. N>=3 per point.

## 8. Risks

| risk | note |
|---|---|
| **B4 antenna-count change** | 16-RX is wired through `MAX_ANT`, scratch allocation, `defs_gNB.h`. Highest risk item; do it behind a knob and keep Cat-A on the 16-RX path. |
| **Per-layer BFW still required for 2 UEs** | Independent of Track B. One combined stream cannot serve two co-scheduled UEs; `oaioran.c` emits layer 0 only. Track B does NOT fix this. |
| SRS enablement is a prerequisite, not part of this | `CATB_ORU_SRS_SCOPE.md`; its W3 is unverified and may be a second work item |
| Deleting reconstruction removes the fallback | Once `applied[]` is gone there is no path back to Track A without a revert. Keep Track A on its own branch. |
| Sounding period interacts with OLLA | OLLA converges over ~160 s; sounding period changes SINR on a ms scale. 180 s per point minimum, as always. |

## 9. Sequencing — recommended

1. **Finish Step 4 on Track A.** Fix the `h_eff` collapse (cache `h_eff` from reference symbols
   where all 16 antennas are real). This is the only path to the FH-latency deliverable.
2. **Then O-RU SRS** (`CATB_ORU_SRS_SCOPE.md`) — verify W3 first.
3. **Then Track B**, which is largely *deletion* once SRS works.

Doing Track B first would abandon the FH-latency measurement the project exists to produce.
