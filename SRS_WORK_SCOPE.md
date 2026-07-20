# SRS Work Scope — full enablement through MU-pairing (2026-07-19)

**Starting point (verified in-tree today):**
- RRC/MAC side EXISTS: `do_SRS=1` configures resources (`usage=codebook`), `gNB_scheduler_srs.c`
  schedules occasions, `handle_nr_srs_measurements` (`gNB_scheduler_ulsch.c:1520`) consumes
  indications. `do_SRS=1` ran stably on 07-14 (attach OK) but produced ZERO measurements.
- gNB PHY receive EXISTS: `openair1/PHY/NR_TRANSPORT/srs_rx.c` (`nr_get_srs_signal`, 167 lines).
- FH transport MISSING: `oaioran.c` has **zero** SRS code (PRACH has a dedicated
  `read_prach_data`/`xran_is_prach_slot` path = the template); xran lib supports SRS
  (`srsEnable/srs_conf{symbMask, eAxC_offset}` in `oran-config.c`) but nothing populates it.
- UE-side SRS TX: presence UNVERIFIED in this tree (only proto header matched a grep) — Phase-0 item.
- Cat-A detail that matters: ALL UL PRBs already ship as full-band IQ per symbol on the PUSCH
  eAxCs; SRS symbols may need only DEPOSIT-side routing, not new streams (the "cheap path").

**Value ledger (why bother):** stock OAI MAC pairs MU UEs blindly; measured spread between
orthogonal and same-direction pairs = 426 vs 35 agg (≈12×) at equal SNR. SRS-driven pairing is
the entry ticket to the CDL/mobility phase (channel-constructed orthogonality doesn't exist there).
Secondary: SNR→MCS seeding (fade recovery 2-3× on mobile), subband scheduling, per-RB blacklist.
NOT applicable here: UL TPMI/codebook precoding (UEs are 1-TX), nonCodebook/antennaSwitching
(unimplemented upstream).

---

## Phase 0 — Discovery (1 day)

1. UE TX capability: does this OAI UE transmit SRS when RRC-configured? (grep nr_ue_procedures /
   srs_modulation; run do_SRS=1 + UE-side log probe). If missing → add UE TX (upstream OAI has it;
   may be a port).
2. DU L1 request path: with do_SRS=1, does the FAPI UL_tti_req carry SRS PDUs down to fhi_72, and
   does the UL C-plane request the SRS symbols? (log probe at the fhi_72 UL section builder).
3. Indication plumbing: trace nfapi srs_indication L1→MAC (exists per :1520 consumer; confirm the
   L1 producer fires when srs_rx runs).
4. Symbol placement audit: where do scheduled SRS occasions land (last symbols of UL slots) and
   what they collide with — NOTE: our TDA14 lever uses symbol 13 on PUCCH-free slots; SRS slots
   must fall back to 13-sym TDA (get_best_ul_tda already demotes conflicting TDAs if SRS marks
   vrb_map — verify it does).
   ⚠ do_SRS=1 also adds SLIV(0,12) TDA twins → TD-field/DCI sizing changes → re-validate attach
   (the rev-172 0_0/0_1 size-tie lesson).

## Phase A — FH transport (2-4 days)

Two routes; decide after Phase 0 item 2:
- **A-cheap (preferred if viable):** extend the DU-side UL deposit loop in `oaioran.c` to also
  copy the SRS symbols from the existing PUSCH eAxC buffers into rxdataF (full-band IQ already
  flows in Cat-A). No RU changes, no new eAxC. Risk: xran may not generate U-plane sections for
  symbols the C-plane didn't describe as PUSCH — if so, add the SRS symbols to the UL C-plane
  section description instead of new streams.
- **A-proper (fallback / spec-clean):** populate `srsEnable/srsEnableCp/srs_conf` (symbMask,
  eAxC_offset), allocate SRS eAxC IDs, add a `read_srs_data()` in `oaioran.c` mirroring
  `read_prach_data`, and the RU-side equivalent. More FH load (extra streams), more code, matches
  O-RAN spec semantics.
- Env-gate: `OAI_FH_SRS=1` (default off). Validation: SRS symbol IQ non-zero in rxdataF at the
  scheduled occasions (probe print, rate-capped).

## Phase B — PHY receive + ground-truth validation (1-2 days)

1. Confirm `nr_get_srs_signal` runs and produces per-antenna channel estimates; wire/verify the
   nfapi srs_indication to MAC (`handle_nr_srs_measurements` fires, per-UE).
2. **Ground-truth check (unique to this lab):** under OLDF steering the true spatial signature is
   the injected DFT beam w[u][a] = exp(j2π·a·ang_u) with known ang_u per UE. The SRS-estimated
   per-antenna vector must match (cosine similarity ≥ ~0.95). This validates the entire
   transport+receive chain against a known answer — no other testbed gets this for free.
3. Bank an N=3 no-regression ladder (SRS on, consumers off): throughput must stay in the
   374-404 band; SRS overhead ≈ 1 symbol per period per UE (~1-2%).

## Phase C — Consumers (independent, orderable by value)

- **C1: SNR→MCS seeding (1 day).** Use SRS wideband SNR to seed `ul_bler_stats.mcs` post-attach /
  post-fade instead of OLLA's +1-per-10-frames climb. Static-lab value: ramp time only. Mobile
  value: 2-3× during fade recovery. Env `OAI_SRS_MCS_SEED=1`.
- **C2: MU pairing screening (3-5 days) — THE 12× lever on realistic channels.** Compute per-pair
  correlation from SRS estimates: corr(u,v) = |h_u·h_v*|/(|h_u||h_v|), refreshed per SRS period,
  stored per UE-pair at MAC. Gate the cosched path (the mu_regime block in pf_ul): if
  corr > threshold (start 0.5), defer one UE to alternate slots (FDM/TDM fallback) instead of
  co-scheduling. Validate on CDL channels (rev-129 thread): expect the 35-Mbps same-direction
  disasters to disappear while orthogonal pairs keep 400+. Env `OAI_MU_PAIR_SCREEN=<corr_thr>`.
- **C3: beamManagement usage (1-2 days, optional).** `usage=beamManagement` gives wideband SNR +
  per-RB UL blacklisting (ulprbbl) — subband awareness for frequency-selective channels. Validate
  on CDL with delay spread.
- **C4: out of scope.** TPMI/codebook precoding (needs ≥2-TX UE), nonCodebook, antennaSwitching
  (unimplemented upstream).

## Phase D — Cash-out campaign (CDL/mobility, separate plan)

SRS+C2 is the prerequisite for: MU-MIMO under TR 38.901 CDL, mobility (VRTSIM_UE_SPEED_KMH),
and the N_UE=3-4 direction (pairing selection only becomes a real decision with more UEs than
layers). Scope that campaign separately once B lands.

## Effort & risk summary

| Phase | Effort | Risk | Gate |
|---|---|---|---|
| 0 discovery | 1 d | none | — |
| A transport | 2-4 d | xran section semantics; FH timing at 16-RX load | IQ-present probe |
| B validate | 1-2 d | none (measurement only) | beam-match ≥0.95 + no-regression N=3 |
| C1 seed | 1 d | low | ramp-time A/B |
| C2 pairing | 3-5 d | scheduler edits (mu_regime path) | CDL disaster-pair A/B |
| C3 subband | 1-2 d | low | CDL-DS A/B |

Total to C2-validated: ~2 weeks alongside normal ladder discipline (env-gate everything,
default off; build in `openairinterface5g/build/`; N=3 clean-draw gates; 8-RX check before commit).

Related docs: `UE_UL_FEED_OPTIMIZATION_PLAN.md` (Option 3), `COMMIT_PLAN_UNCOMMITTED_TREE.md`,
memory `project_oran_iq_sweep.md` revs 195-223 + `reference_oran_phy_arch.md` (SRS status 07-14).
