# Cat-B UL combining — status, debug ledger, and method notes

Last updated 2026-08-19. Companion to `CATB_HANDOFF.md` (§17–§27 hold the blow-by-blow).
This file is the **standalone summary**: what is proven, what is not, what was retracted,
and the techniques/traps that actually mattered.

---

## 1. BOTTOM LINE

**Cat-B UL combining is IMPLEMENTED but NOT VALIDATED. Throughput is 0.0 Mbps.
The combined path has never decoded a transport block.**

**Cat-A is unregressed: 174.3 Mbps, MCS 28/28, attach 2/2** (measured twice on the current tree).

### Record correction — read before citing any earlier number
§17 claimed "first decode — 3.1 Mbps". **That was decoding the ~95% of data symbols the RU
forwarded UNCOMBINED**, through the DU's ordinary per-antenna path. Raise coverage to 100% and
throughput goes to ZERO. Corrected in §21. **Do not cite 3.1 Mbps as evidence Cat-B works.**

---

## 2. TREE STATE

| repo | path | branch | commit |
|---|---|---|---|
| oran_lab | `/home/jesse/oran_lab` | `catb-srs-ru-mmse` | `a30cc8d` |
| openairinterface5g | `oaicicd/test_dir/openairinterface5g` | `catb-instrumentation` | `8f90259139` |
| phy-f-1.0 (xran) | `oaicicd/test_dir/phy-f-1.0` | `xran-timescale` | `ba5dfd8` (pristine) |

**UNCOMMITTED:** `catb_bfw_attach` harvest PRB changed `n_prb/2` -> `n_prb/4` (built into
`liboran_fhlib_5g.so`, never run — see §6).

Cat-A vs Cat-B is selected by ENV VARS at runtime; every Cat-B knob defaults OFF.
**Never switch branches to run the Cat-A control** — see `CATA_CONTROL_RUNBOOK.md`.

---

## 3. PASS — eight blockers closed, each proven by a metric that MOVED

| # | bug | fix | proof |
|---|---|---|---|
| 1 | RU combined only 5% of data symbols | period-scoped lookup via `catb_period_first_ul_slot()`, derived from `nTddPeriod` + `sSlotConfig[].nSymbolType[]` | coverage 5% -> **100%**; lookup `0/9128 -> 5754/9128` |
| 2 | Weight production deadlocked on co-scheduling | SU fallback (later made opt-in) | publishes **114 -> 1501+** |
| 3 | SU published ALL-ZERO weights | `det = (\|h0\|^2+nvar)*nvar` is proportional to nvar; measured `nvar=0`. Floored regulariser at 1 | `singular_prb` **106/106 -> 0/106** |
| 4 | **DU receive ring NEVER MAPPED** | `catb_read_applied_weights()` retried its own handle every 2000 calls, but that path runs a few hundred times/run when nothing decodes — a deadlock. Use `catb_get_ring()`'s handle (same process) | `applied_read` hit/call **0 -> 100%** |
| 5 | SU beam nulled the co-scheduled UE's Msg3 | `OAI_CATB_SU_BFW`, default OFF | attach **1/2 -> 2/2**, reproducible 3/3 |
| 6 | TWO publishers on ONE ring | MU-IRC exporter read past `chF2`'s populated extent (`re = prb*12+6` vs 6-RE/PRB DMRS packing) and published half-zero records over the good ones. `OAI_CATB_PUB_IRC`, default OFF | record **1590/3392 -> 3392/3392** |
| 7 | `>>15` INSIDE the 16-term accumulate loop | accumulate full precision, shift once (legal in int32 only because w is L1-normalised, bounding the sum at 1.07e9) | removing it made `\|combined\|` SMALLER — proving the old larger value was rounding residue |
| 8 | **BFW byte order + ext-1 payload offset** | (a) host LE went on the wire; O-RAN is network order -> swap into `iq_be[]`. (b) RU read at `ext+4`; the ext-1 header is 3 bytes and compMeth=0 has no `bfwCompParam` -> `ext + sizeof(*ext)` | synthetic ramp **bit-exact**: `240,480,...,1920`; wire bytes `00 f0 00 00 01 e0 ...` |

**Bug 8 is the one to understand.** Each half alone produces obvious garbage. TOGETHER they yield a
clean `value & 0xFF00`, which reads as a legitimate 8-bit precision limit — so it survived nine
other hypotheses, all of which measured "healthy", and sent the investigation after `bfwIqWidth`
and `XRAN_MAX_SET_BFWS` (neither was involved).

---

## 4. NOT SURE — plausible, unproven

| item | status |
|---|---|
| **Conjugation fix** — `W = G^-1 H^H` already carries the conjugate, so apply `sum_a w_a x_a` (plain product), not `x*conj(w)` | Correct by derivation. Both conventions were then measured on identical samples: `coh_xw=0.202-0.289` vs `coh_xconjw=0.237-0.324` — NEITHER coherent. Kept, but **not** the loss. |
| **`n_prb/4` harvest PRB** | Built, **NEVER RUN**. For 106 PRB, `first_carrier_offset=900` and `900 + 53*12 = 1536 == 0`, so `n_prb/2` is the DC-straddling PRB. Measured per-PRB coherence with weights harvested there: `prb0=0.413 prb26=0.336 prb53=0.136 prb79=0.205` — the weights' OWN PRB reads LOWEST. |
| **~6% degenerate channel estimates** | 7 of 114 `HPROF` samples read `65,0,0,0,...` — antenna 0 only, 15 EXACT zeros. Exact zeros are an unpopulated buffer, not fading. Cause unknown. Real defect. |
| **Remaining loss term** | Coherence at real PRBs is 0.34–0.45 against a ~0.63 ceiling (see §5). Something else is still wrong and is NOT identified. |

### Known structural caps (not bugs — design limits of Step 3a)
- **Layer-0 only.** `oaioran.c` emits layer 0's weights; the RU produces ONE combined stream.
  **One stream cannot serve two co-scheduled UEs**, so the 2-UE config is capped short of the
  Cat-A number regardless of everything above. Needs per-layer BFW on distinct eAxC.
- **Wideband.** One vector for the whole allocation. NOTE this was investigated and REFUTED as the
  current blocker (§5) — it is a bounded accuracy cost, not the reason throughput is zero.

---

## 5. RETRACTED — do NOT re-run these

1. **"Wideband BFW is the blocker."** Refuted TWICE. (a) DS sweep: `CHAN_DS_US=0.005`
   (coherence BW ~32 MHz vs a 38 MHz band, 20x flatter) gives ratio **0.211** against **0.209** at
   DS=0.1us. (b) Per-PRB coherence shows **no peak at the weights' own PRB**. Frequency
   selectivity is fully excluded. `XRAN_MAX_SET_BFWS` was the wrong tree (reverted to 1; the
   enlargement to 64 was proven SAFE and the rebuild recipe is in §24 if ever needed).
2. **"Coherence = 0.25 = 1/sqrt(16) proves incoherent combining."** INVALID MEASUREMENT — the probe
   sampled `ofdm_symbol_size/2`, which is the GUARD BAND in OAI's rxdataF (DC at index 0, spectrum
   wraps). It compared weights against noise, returning 1/sqrt(16) BY CONSTRUCTION.
3. **"CHANMOD=0 is a usable flat-channel control."** No — all antennas see an identical signal, H is
   rank-1, the MMSE solution is degenerate and unstable: ratio spanned **0.175–0.874 across four
   runs of an IDENTICAL config**. §24's "first data, 0.086 Mbps climbing" was N=1 and did not
   reproduce.
4. **"Antenna mapping is permuted."** The synthetic ramp arrives in order — mapping is 1:1.
5. **"Weight degeneracy."** `w_zeroed=0/16`, `dd=4.6e20`, `w_spread` tracks `h_spread`. Weights are
   well-formed. (Run 34's one-antenna vector was a transient — and a one-term sum is trivially
   "coherent", which is why it read 0.66–0.89 and meant nothing.)

### Interpreting coherence — the ceiling is NOT 1.0
Per-antenna per-RE SNR is only **~4.6 dB** (RU `rms|x_a|` 18–25 against a `sqrt(2)*sigma = 9.9`
thermal floor at `VRTSIM_RX_NOISE_SIGMA=7`). With PERFECT weights, coherence tops out near **0.63**,
not 1.0 — signal sums coherently as `16|h|^2` while noise sums as `sqrt(16)|h||n|`. Measured
0.34–0.45 is above the 0.25 random floor but below that ceiling.

---

## 6. NEXT STEPS, in order

1. **Run the `n_prb/4` harvest change** (built, uncommitted). One run. If coherence rises toward
   0.63 and ratio toward 1.4, the DC-PRB harvest was a loss term.
2. **Fix the ~6% degenerate channel estimates.** Independent real defect; weights published from
   `65,0,0,...` are worthless.
3. **Per-layer BFW on distinct eAxC.** Required for any 2-UE number.
4. Only then chase the residual gap to the Cat-A baseline.

**Step 4 (the project deliverable — degradation surface vs weight-loop delay) is BLOCKED** on the
above. A Cat-A proxy sweep can produce the curve, but `d` is then a free parameter with no
referent, which is why Step 3 was being finished first.

---

## 7. METHOD — what actually worked

### The synthetic reference vector (this is what cracked bug 8)
Magnitude probes were exhausted: at ~4.6 dB per-antenna SNR, ANY measurement derived from received
magnitudes is noise-limited — which is why FIVE probes in a row gave plausible-but-wrong answers.
Instead publish a vector whose ANTENNA ORDER is unmistakable:

```
w_a = (240*(a+1), 0)  ->  240,480,...,3840
L1 = 240*136 = 32640 <= 32767, so the normaliser is a NO-OP and cannot rescale or reorder it.
OAI_CATB_WSYNTH=1, default off. Destroys decoding for the run, by design.
```

**A known input turns a diagnosis problem into a comparison, and the answer stops depending on
signal quality.** Real weights are unknowable at the far end, so any corruption just looks like
"bad weights".

### Log VALUES, not presence flags
Every diagnosis made by reading code was wrong. Every one made after logging an actual value was
right. `n_ant=16` looked healthy for hours while the vector was all zeros.

### Read cumulative censuses as DELTAS
The `[CATB UL]` coverage census is cumulative; its final line said 63% while steady state was
**100%** (`no_weights` freezes after the first weights land). Same trap caught `applied_read`
(90.5% cumulative, 100% steady). **Difference successive prints. Never read a running total.**

### A modulus-print counter's PRINT COUNT bounds the rate for free
`[CATB] ref-symbol weight publish` prints every 500 and printed ONCE => <501 publishes/run, against
26001 sections on the wire. No new run needed.

### Design probes to PARTITION the space, not confirm a guess
`[CATB PERIOD] same=/diff=` never firing REFUTED a hypothesis in one run instead of a session.
Evaluating both conjugation conventions on identical samples settled that question in one run
instead of an A/B across two.

### FIVE probe defects — all mine, four gave plausible wrong answers
1. Blind sampling (fired on idle slots) -> gate on signal present.
2. Wrong control array (`ul_ch_estimates` raw vs `chFext` post-extraction) -> read zeros.
3. `ofdm_symbol_size/2` is the GUARD BAND in OAI's rxdataF.
4. PRB 53 maps to raw subcarriers 0..11 — straddling DC — for 106 PRB.
5. Absolute PRB (RU) vs ALLOCATION-RELATIVE PRB (DU; `nr_ulsch_extract_rbs` packs from `rb_start`).

**Common thread: I validated WHAT was computed but not WHERE it was sampled.**
**When a probe returns a suspiciously round number (0.25 = 1/sqrt(16)), check the sampling point
BEFORE believing it.**

---

## 8. RIG / HARNESS TRAPS — these cost more runs than the bugs did

### `pkill -f` self-match (~6 runs lost)
`run_multi_ue.sh`'s preflight runs `sudo pkill -9 -f nr-softmodem`. **`-f` matches the ENTIRE
command line**, so any shell whose argv merely MENTIONS the binary is killed — including the one
launching the script. Symptom: log dir created and stays EMPTY, exit 1, no stderr.
**Never put `nr-softmodem` / `nr-oru` / `nr-uesoftmodem` / `ul_saturate.py` in the same command
line that invokes the harness.** Keep cleanup in a SEPARATE call. The script does its own pkill +
hugepage purge + `nr_hugepages` cycle anyway, so manual cleanup is redundant.

Related: `pgrep -c -f "run_multi_ue.sh"` returns 1 with NO orphan — your own shell self-matches.

### `echo 0 > nr_hugepages` IS A KILL SWITCH, not housekeeping
It yanks the pool out from under EVERY DPDK process on the box. It destroyed two of the user's
in-flight runs. `find /dev/hugepages -type f -delete` alone cannot reclaim MAPPED entries, so the
0-then-8192 cycle is the only thing that works — which is exactly why it is dangerous.

**Before ANY destructive rig operation (kill / purge / nr_hugepages / docker restart), check
IMMEDIATELY BEFORE the action, not once at the top of a sequence:**
```bash
pgrep -a -x 'nr-or[u]'; pgrep -a -x 'nr-softmode[m]'   # bracket avoids self-match
```

### Cat-A IS the rig check — run it the moment behaviour gets odd
Both documented preflights are BLIND to the stale-CN failure mode: `docker logs oai-amf |
grep -c "no SMF candidate"` reads 0 THROUGHOUT, and PRACH sits at ~20 dB for BOTH the runs that
attach and those that do not. Cat-A failing to attach is the only reliable signal.
Fix: `docker restart oai-smf oai-upf oai-amf`, wait 35–40 s.
CN staleness tracks ELAPSED TIME, not just run count (recurred after a ~15 h idle gap).

### `timeout` + `tail` HIDES output
`tail` buffers to EOF and is killed with the pipeline, so a HEALTHY run looks like an instant
silent death. Redirect to a FILE and read it afterwards. This defeated three diagnostic attempts.

### Env allowlist trap — still live
`run_du.sh` / `run_ru.sh` pass an explicit `env VAR=` list. An unlisted variable is dropped
SILENTLY and the feature does nothing while the run looks healthy. `OAI_CATB_SU_BFW` and
`OAI_CATB_PUB_IRC` were added to the code but not the allowlist for two commits — harmless only
because their defaults were the desired state. Now added, along with `OAI_CATB_WSYNTH`.

### One run is not a result
N>=3. There is a ~1-in-3 intermittent single-UE fault, and one run this session looked like a
breakthrough and was contradicted by three repeats.

---

## 9. DIAGNOSTIC PROBES CURRENTLY IN THE TREE

All are printf-only and are **STRIP candidates** per `COMMIT_PLAN_UNCOMMITTED_TREE.md`; the
line-level split that plan calls for is still owed.

| probe | where | what it shows |
|---|---|---|
| `[CATB PROD]` | `nr_ulsch_demodulation.c` | weight-production exit census (comb/notdmrs/antmix/ring/dup/nopartner/buf/lowsum/PUB_MU/PUB_SU) |
| `[CATB QUANT]` | `nr_ulsch_demodulation.c` | computed -> quantised at the harvest PRB, + `DEGEN h_spread/w_spread/w_zeroed/dd` |
| `[CATB HPROF]` | `nr_ulsch_demodulation.c` | per-antenna `\|h_a\|` + `rb_start`/`rb_size` |
| `[CATB EXTRACT]` | `oaioran.c` | ring record identity + extracted vector + non-zero scan |
| `[CATB BYTES-DU]` / `[CATB BYTES-RU]` | `oaioran.c` / `oaioran_ru.c` | raw wire bytes both sides |
| `[CATB COH]` | `nr-oru.c` | per-PRB coherence, `\|vec_sum\|/sum\|term\|` |
| `[CATB XPROF]` | `nr-oru.c` | per-antenna `rms\|x_a\|` at the strongest PRB |
| `[CATB MAG-A]` / `[CATB MAG-B]` | `nr-oru.c` / `nr_ulsch_demodulation.c` | `\|combined\|/\|ant0\|` and `\|rx_combined\|`/`\|h_eff\|`/`\|H_ant0\|` |

### Env knobs added (all default OFF, all now in `run_du.sh`'s allowlist)
- `OAI_CATB_SU_BFW=1` — single-user weight fallback. Harmful with 2 UEs (nulls the partner's Msg3).
- `OAI_CATB_PUB_IRC=1` — re-enable the vestigial MU-IRC passive exporter. Publishes broken records.
- `OAI_CATB_WSYNTH=1` — synthetic BFW ramp for transport verification. Destroys decoding.
