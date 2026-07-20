# Uncommitted tree — commit review plan (2026-07-18, rev-205 state)

39 files, +357/−54. Nothing committed. Classification below is KEEP (fix/lever, standards-clean or env-gated-default-off) vs STRIP (diagnostic probe — remove before commit) vs MIXED (file has both; line-level split needed at commit time).

## KEEP — fixes and levers
| File | What |
|---|---|
| `common/platform_constants.h` | MAX_ANT 8→16 (16-RX support) |
| `openair1/PHY/defs_gNB.h` | heap scratch ptrs (VLA fix), power arrays →[MAX_ANT], mu_chest_frame/slot stamps, last_llr_mean, dbg_log2h/dbg_llr (dbg pair = STRIP if FAILCLASS2 stripped) |
| `openair1/PHY/INIT/nr_init.c` | scratch alloc/free for 16-RX demod |
| `openair2/LAYER2/NR_MAC_gNB/nr_radio_config.c` | OAI_UL_DMRS_ADDPOS lever (pos0 = the L6 +10% rung, VALIDATED); OAI_UL_MIXED_TDA lever (measured neutral, default off) |
| `executables/nr-ru.c`, `openair1/PHY/defs_RU.h`, `radio/COMMON/common_lib.h`, `radio/fhi_72/oran-config.c` | RU ring depth + RU-TX fragmentation era fixes |
| `radio/vrtsim/vrtsim.c` (part) | AGC freeze (VRTSIM_AGC_FREEZE), negative atten = gain, align-down connect fix, UL MU steering (ul_mu_w), gnb_num_rx_ant assert |
| `openair1/PHY/NR_TRANSPORT/nr_ulsch_demodulation.c` (part) | 16-RX VLA→scratch, Qm-aware SHIFT_ADJ (adj_eff), phantom-partner gates (energy + freshness), atoi gates, bounce-cap |
| `openair2/LAYER2/NR_MAC_gNB/gNB_scheduler_ulsch.c` (part) | MU cosched machinery (mu_force, port stage, CSS/0_0 defer), atoi×6, B_sized sizing, sched_inactive MU exemption |
| `openair2/LAYER2/NR_MAC_gNB/gNB_scheduler_primitives.c` (part) | preSNR antenna-generic path (if present here) |

## STRIP — probes (printf diagnostics, no behavior)
| File | Probe |
|---|---|
| `openair1/PHY/NR_TRANSPORT/nr_prach.c` | PRACHPAIR lifecycle |
| `radio/fhi_72/oaioran.c` (part) | PRACHPAIR + mask fix (mask fix = KEEP; split) |
| `openair1/PHY/NR_TRANSPORT/nr_ulsch_decoding.c` | DECPARAM + dbg_log2h/dbg_llr capture |
| `openair1/SCHED_NR/phy_procedures_nr_gNB.c` | FAILCLASS/FAILCLASS2, VALPROBE, OAI_ULSCH_TRACE_CAP ACK/NAK traces (keep the atoi'd mu_tp gate = it's IRC hoist behavior) |
| `openair1/PHY/NR_UE_TRANSPORT/dci_nr.c` | PDCCHATT + LOG_D→LOG_I bump |
| `openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c` | UETBS |
| `gNB_scheduler_ulsch.c` (part) | ULDCI printf ×2, [MU STATE]/[MU DEFER] rate-capped LOG_E |
| `gNB_scheduler_primitives.c` (part) | VALPROBE at DCI encode |
| `vrtsim.c` (part) | AGCPAIR, UEMERGE, FIRSTWR, TAPENERGY, RDMARGIN |
| `nr_ulsch_demodulation.c` (part) | MU METRIC extended fields, REQUEUE GIVEUP print, last_llr_mean capture (strip if unused after servo revert) |

## Harness (oran_lab, not in repo)
- `run_du.sh`: env allowlist grew (SHIFT_ADJ, DMRS_ADDPOS, MIXED_TDA)
- `run_multi_ue.sh`: min_grant_prb sed now `${MIN_GRANT_PRB:-273}` (proven default restored; 24/261 = slot-19 experiment knobs)
- `run_ue.sh`: AGC_FREEZE forward, DU_EXTRA_ARGS hook

## Open items blocking a clean commit
1. Line-level split of MIXED files (do with `git add -p` at review time).
2. Decide fate of parked levers: OAI_UL_MIXED_TDA (neutral), slot-19 code fixes (B_sized + sched_inactive exemption — currently harmless with min_grant 273; keep as they encode real defects).
3. 8-RX regression untriaged — commit may want to wait for that re-validation.

Validated recipe as of rev-205 (L6, campaign best 333 sim-Mbps agg @30 dB):
`NB_ANT_RX=16 NB_ANT_TX=2 TS=0.04 OAI_FH_UL_SLOT_DELAY=3 SL_AHEAD=13 OAI_FH_SPIN_CAP=30000 VRTSIM_AGC_FREEZE=1 OAI_UL_MU_IRC=0 OAI_UL_MU_SHIFT_ADJ=3 OAI_UL_MU_COSCHED=1 OAI_UL_MU_PORTS=1 VRTSIM_UL_MU_STEER=1 OAI_UL_DMRS_ADDPOS=0` (CHANMOD off, min_grant 273)
