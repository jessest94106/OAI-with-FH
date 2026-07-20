# gNB Hardware-Impairment Injection — Scope Plan (2026-07-19)

**Goal:** inject parameterized RF impairments — residual Doppler/CFO, phase noise, IQ imbalance,
PA nonlinearity — into the vrtsim testbed with physically correct placement and per-impairment
validation, so the receiver chain (now validated clean: MCS 26-28 @ ~1% BLER, chains 0) can be
studied under realistic hardware degradation, and mitigations (PTRS, tracking, backoff) measured.

**Placement principle (physical signal order):**
UE PA → air channel (Doppler) → gNB RX RF (phase noise, IQ imbalance) → quantization (BFP-9 is
the existing ADC proxy) → digital RX. All injection must happen BEFORE the FH BFP compression —
i.e., in the **vrtsim server merge path** (runs in the RU process = the gNB radio boundary),
where per-(UE, antenna) time-domain samples are already exposed. This is the same code family as
the existing steering/AGC/tap machinery (vrtsim.c merge loop ~:1543+), and the time-varying
steering (`VRTSIM_UL_MU_TV`, phase-ramp math) is a working template for per-UE phase rotation.
`noise_device.c` (AWGN) is the existing impairment precedent.

**Impairment→injection-point map (UL focus; DL = mirror on the server→client write path):**

| Impairment | Physical source | Inject on | Model |
|---|---|---|---|
| Doppler residual / CFO | UE-gNB LO offset + motion residual after sync | per-UE, pre-merge | y[n] = x[n]·e^{j2πΔf·n/fs}, Δf per UE |
| Phase noise | gNB RX LO jitter | per-antenna (or common-LO switch) post-merge | Wiener: φ[n+1]=φ[n]+N(0,σ²), σ² from linewidth; y=x·e^{jφ} |
| IQ imbalance | gNB RX I/Q mixer mismatch | per-antenna, post-merge | y = α·x + β·conj(x); α,β from gain ε(dB) + phase φ(deg); static per antenna, seeded |
| PA nonlinearity | UE TX PA (UL) / gNB TX PA (DL) | per-UE pre-channel (UL); DL path (Phase 4b) | Rapp: y = x/(1+(|x|/x_sat)^{2p})^{1/2p}; params IBO (dB), p |

---

## Phase 0 — Framework + budget check (1-2 days)

- One injection module (`vrtsim_impairments.c/h` beside noise_device): seeded xorshift RNG
  (reproducible draws — pass seed via env, NO rand()), per-UE and per-antenna hook points in the
  merge loop, SIMD-friendly batch processing (the aligned-buffer pattern at ~:1182).
- Env config family, all default-off:
  `VRTSIM_IMP_CFO_HZ="f0,f1"` (per UE) · `VRTSIM_IMP_PN_LINEWIDTH_HZ` + `VRTSIM_IMP_PN_COMMON=0/1`
  · `VRTSIM_IMP_IQ_GAIN_DB` + `VRTSIM_IMP_IQ_PHASE_DEG` (+ per-antenna random spread + seed)
  · `VRTSIM_IMP_PA_IBO_DB` + `VRTSIM_IMP_PA_P` · `VRTSIM_IMP_SEED`.
- **CPU headroom check FIRST** (the rev-6 lesson: in-process instrumentation perturbs the
  timing-sensitive server): measure merge-loop time/batch before/after a no-op hook at TS=0.04
  16-RX; budget each impairment (sin/cos per sample → use phase-recursion complex multiply, no
  libm in the loop).
- **Attach-safety gate:** reuse the steering trigger-file pattern (`ul_mu_steer_active`) —
  impairments optionally ramp in only after both UEs attach (`VRTSIM_IMP_AFTER_ATTACH=1`
  default), since PRACH/msg3 tolerance is a separate study.
- Fixed-point audit: PA reshapes amplitude distribution; IQ/PN preserve power; verify int16
  headroom + AGC interaction (run with `VRTSIM_AGC_FREEZE=1` as in the recipe).

## Phase 1 — CFO / Doppler residual (1 day; validates the framework)

- Per-UE phase ramp (identical math to `ul_mu_tv` — mostly plumbing).
- Validation ladder: Δf = 0 / 50 / 200 / 500 / 1500 Hz.
  Expected physics: DMRS-based per-slot chest absorbs slow rotation; ICI ∝ (Δf/SCS)² —
  at 30 kHz SCS, 200 Hz ≈ harmless, 1500 Hz ≈ measurable SNR loss; the UE/gNB tracking loops'
  residual behavior is itself a finding.
- Ground truth: injected Δf must appear in the gNB's TA/CFO estimates (probe) before any
  throughput reading is trusted.

## Phase 2 — IQ imbalance (1-2 days; cleanest validation)

- Static per-antenna α/β multiply.
- **Analytic check:** image-rejection ratio IRR = f(ε, φ) (e.g. ε=0.5 dB, φ=5° → IRR ≈ 26 dB)
  caps post-combine SINR at ≈ IRR → predicted MCS ceiling; measured preSNR/MCS must match the
  formula. 16-RX nuance worth measuring: independent per-antenna imbalance partially averages
  out in MRC (diversity gain on the image), unlike common imbalance.
- Sweep: ε ∈ {0.1, 0.5, 1, 2} dB, φ ∈ {1, 5, 10}°.

## Phase 3 — Phase noise (2-3 days; pairs with a mitigation study)

- Wiener process per antenna; `PN_COMMON=1` = one LO shared by all 16 chains (realistic
  single-box gNB; makes it a pure common-phase-error) vs independent (distributed RU study).
- Physics split worth measuring: CPE (common rotation per symbol — correctable) vs ICI
  (linewidth ~ SCS — not correctable). Sweep linewidth 100 Hz … 10 kHz.
- **Mitigation arm: PTRS.** OAI supports UL PTRS (`configuration->ptrs` — currently NULL in
  config_pusch, i.e. off). Enable via the existing `config_ulptrs` path (env-gated like
  ADDPOS) → measures PTRS's CPE-correction value under injected PN. This is the headline
  experiment of the phase: PN sweep × {PTRS off, PTRS on}.
- Note: 1-DMRS pos0 (our recipe) is maximally PN-vulnerable (no mid-slot phase reference) —
  expect pos0-vs-pos2-vs-PTRS to reorder under PN. Document the recipe's PN tolerance envelope.

## Phase 4 — PA nonlinearity (2-3 days)

- 4a UL: Rapp model on each UE's TX samples (client-side write path or server pre-merge).
  Sweep IBO {10, 6, 3, 1} dB, p ∈ {2, 3}. Expected: EVM floor → MCS ceiling; OFDM PAPR ~8-10 dB
  means IBO 6 dB already clips tails. Cross-check: measured EVM vs Rapp+PAPR theory.
  Secondary observable: spectral regrowth into guard PRBs (probe FFT of out-of-allocation power)
  — relevant later for adjacent-carrier studies.
- 4b DL: same model on the gNB TX (server→client direction) — affects PDCCH/PDSCH → UE-side
  decode; validates the DL path injection plumbing (attach sensitivity!).
- Interaction to document: PA clipping vs BFP-9 compression (two nonlinearities in series —
  order matters and ours is now physical: PA before compression ✓).

## Phase 5 — Combined profiles + campaign integration (1-2 days)

- Named profiles (one env: `VRTSIM_IMP_PROFILE=clean|typical|worst`):
  e.g. "typical commercial": CFO 200 Hz, PN 1 kHz common, IQ 0.5 dB/2°, PA IBO 8 dB.
- N=3 ladder per profile vs the 404 baseline → the paper-grade table: throughput/MCS/BLER
  degradation per impairment and combined, with mitigation arms.
- Natural composition with the other scoped work: impairments × CDL channels (rev-129 thread),
  impairments × SRS-pairing (SRS estimates degrade too — pairing robustness), and the afflicted
  attach-lottery may itself be impairment-sensitivity of initial sync (bonus insight).

## Traps (from campaign history)

- Perturbing-instrument trap (rev-6): heavy per-sample math or printfs in the server loop breaks
  cold-start timing — budget first, phase-recursion not sin(), rate-cap all probes.
- Attach fragility: default `AFTER_ATTACH=1`; separate study for impaired-attach.
- AGC: run frozen; impairment power shifts otherwise re-trigger the rev-161 transition bursts.
- Draw discipline unchanged: env-gate everything default-off, N=3 clean-draw gates, build in
  `openairinterface5g/build/`, 8-RX check before commits.

## Effort summary

| Phase | Effort | Headline deliverable |
|---|---|---|
| 0 framework | 1-2 d | seeded, budgeted, attach-safe injection module |
| 1 CFO | 1 d | framework validated vs known Δf |
| 2 IQ | 1-2 d | analytic IRR↔SINR match + 16-RX averaging finding |
| 3 PN | 2-3 d | PN sweep × PTRS mitigation table |
| 4 PA | 2-3 d | IBO sweep, EVM↔theory match, DL arm |
| 5 profiles | 1-2 d | degradation table vs 404 baseline |

Total ≈ 2 weeks. Independent of `UE_UL_FEED_OPTIMIZATION_PLAN.md` and `SRS_WORK_SCOPE.md`
(all three can interleave; impairments and SRS compose in Phase 5/D respectively).
