# O-RU SRS forwarding — SCOPE (rev 2, W3 resolved)

2026-08-19. **Critical path for Track B** (`CATB_TRACKB_SCOPE.md`), not a follow-on.
Goal: `do_SRS=1` produces real measurements end-to-end over the 7.2 split.

Rev 2 supersedes rev 1: W3 ("does the DU RX route SRS?") is now **answered — it does not**, and
the work is bigger than one function. Scope below reflects that.

---

## 1. Why it's missing (settled, don't re-investigate)

OAI implements the **O-DU only**; the O-RU is vendor hardware. Verified: `oaioran_ru.c` and
`nr-oru.c` are **absent from `origin/develop`** — our RU is this project's own. Checked
`SRS_rebase`, `SRS_improvements`, `aperiodic_SRS`, `aerial_srs_mMIMO`: each touches one non-YANG
`fhi_72` file, only to *print* SRS config. **Nobody upstream forwards SRS from an RU because
nobody upstream has an RU.**

## 2. What exists vs what's missing — VERIFIED

| piece | where | state |
|---|---|---|
| MAC SRS scheduling | `gNB_scheduler_srs.c` | ✅ (`do_SRS=1` ran stably 07-14) |
| DU PHY receive | `srs_rx.c: nr_get_srs_signal()` | ✅ starved |
| DU channel estimation | `nr_ul_channel_estimation.c:787` | ✅ |
| slot wiring | `phy_procedures_nr_gNB.c:1010`, gated `if (*srs_est >= 0)` | ✅ |
| MAC consumer | `handle_nr_srs_measurements()` | ✅ |
| xran config | `xran_init_srs()` (`xran_main.c:215`) | ✅ |
| **xran registration API** | **`xran_5g_srs_req()` (`xran_fh_o_du.h:1025`)** | ✅ **exists — mirrors `xran_5g_prach_req()`:1001** |
| xran RX counter | `rx_srs_packets` | ✅ reads 0 |
| **DU SRS buffers** | `oran_buf_list_t` has `src/srccp/dst/dstcp/bfwrxcp/bfwtxcp/prachdst` — **NO `srsdst`** | ❌ **MISSING** |
| **DU SRS read path** | `read_prach_data()` exists; **no `read_srs_data()`** | ❌ **MISSING** |
| **O-RU SRS transmit** | `xran_oru_send_prach()` / `_pusch()` exist; **no `_srs()`** | ❌ **MISSING** |

**Three missing pieces, not one.** DU-side buffers + read path, and RU-side transmit.

## 3. The contract (compatibility with DU SRS)

`nr_get_srs_signal(gNB, c16_t **rxdataF, slot, srs_pdu, nr_srs_info, srs_received_signal[][], srs_received_noise[][])`

| requirement | value | source |
|---|---|---|
| domain | frequency-domain, in `rxdataF` | DU does not FFT SRS separately |
| antennas | **ALL 16, UNCOMBINED** | SRS exists to give the 16-antenna channel |
| symbol index | `(slot % RU_RX_SLOT_DEPTH) * symbols_per_slot + sym` | `srs_rx.c:86` |
| span | `ofdm_symbol_size * (1 << srs_pdu->num_symbols)` per antenna | output array sizing |
| eAxC | separate range at `fh_cfg->srs_conf.eAxC_offset` | `xran_init_srs()` |
| compression | same `ru_conf.compMeth` / `iqWidth` as PUSCH | reuse PUSCH compress path |

**Rule: forward SRS exactly like Cat-A PUSCH — per-antenna, no beamforming — on a different eAxC
in the SRS slot.** PRACH is the structural template throughout; it is the existing, working
example of a second eAxC stream with its own buffers, registration and read path.

---

## 4. WORK ITEMS

### S1 — DU: SRS buffer set  *(prerequisite for everything)*
- Add `struct xran_buffer_list srsdst[XRAN_MAX_ANTENNA_NR][XRAN_N_FE_BUF_LEN];` to
  `oran_buf_list_t` (`oran-init.h:46-60`).
- Allocate alongside `prachdst` in `oran-init.c`.
- **Copy the `prachdst` pattern exactly** — sizing, alignment, `XRAN_N_FE_BUF_LEN` depth.

### S2 — DU: register with xran
- Call **`xran_5g_srs_req()`** (`xran_fh_o_du.h:1025`) next to the existing
  `xran_5g_fronthault_config()` / PRACH request in `oran-init.c`.
- Needs its own callback + tag, mirroring `pusch_tag`. **Do not alias buffers** — §3a.2 already
  cost this project runs by aliasing `srccp/dstcp`; the file comment at `oran-init.c:406` records it.

### S3 — RU: `xran_oru_send_srs()`  *(the core transmit)*
Mirror `xran_oru_send_prach()`. Per RX antenna, in the SRS slot, per SRS symbol:
build eCPRI + radio-app + section headers, compress per `ru_conf`, resolve VF with
`xran_map_ecpriPcid_to_vf(gxran_handle, XRAN_DIR_UL, 0, aarx + fh_cfg->srs_conf.eAxC_offset)`,
send via `xran_ethdi_mbuf_send()`.
Second reference: xran's own O-RU emulation, `app_io_fh_xran.c` `p_tx_srs_play_buffer` (~L1474) —
and `xran_srs_config.slot / ndm_offset / ndm_txduration` are commented **"for O-RU emulation"**.
**Env-gated, default OFF** (`ORU_SRS_TX=1`).

### S4 — RU: drive it from the slot loop
Add the SRS-slot branch where `xran_oru_send_pusch()` is driven. Take slot/symbols from
`fh_cfg->srs_conf` (populated by `xran_init_srs()`) — **never hardcode**.

### S5 — DU: `read_srs_data()`
Mirror `read_prach_data(ru, frame, slot)`, called from the same place in `oaioran.c`.
Must land samples in `rxdataF[ant]` at the offsets in §3 — that is the whole compatibility surface.
**Note the PUSCH demux at `oaioran.c:906-930` reads only `dstcp`; SRS will not appear there.**

### S6 — Config + allowlist
- `du_test.conf: do_SRS = 1`
- `srs_conf.eAxC_offset` — must not collide with PUSCH or PRACH ranges; **assert non-overlap at init**
- Add `ORU_SRS_TX` (and any new knob) to the `run_du.sh` **and** `run_ru.sh` allowlists —
  an unlisted variable is dropped **silently** (has bitten 3x this project).

---

## 5. VERIFICATION LADDER — stop at the first rung that fails

| # | check | how |
|---|---|---|
| 1 | packets arrive | `rx_srs_packets` non-zero (currently 0) in `[FH RXCLS]` |
| 2 | packets parse | `nr_get_srs_signal()` returns `>= 0` |
| 3 | estimation runs | `nr_srs_channel_estimation()` reached (`phy_procedures_nr_gNB.c:1010`) |
| 4 | MAC receives | `handle_nr_srs_measurements()` fires |
| 5 | **correctness** | SRS per-antenna `\|H_a\|` **matches the PUSCH-DMRS one in the same slot, within noise** — reuse the existing `[CATB HSUM]` probe |
| 6 | no regression | Cat-A control unchanged with `ORU_SRS_TX=0`: ~174 Mbps / MCS 28,28 (`CATA_CONTROL_RUNBOOK.md`) |

Rung 5 is the real acceptance test: it proves the SRS channel is the *same physical channel* the
DMRS path measures, which is the only thing Track B needs from it.

---

## 6. Risks

| risk | mitigation |
|---|---|
| eAxC collision with PUSCH/PRACH | assert non-overlap at init; PRACH already occupies a second range |
| buffer aliasing | §3a.2 precedent — dedicate `srsdst`, never reuse `dstcp`/`prachdst` |
| SRS slot ≠ what MAC scheduled | drive both from `srs_conf`; log the slot on both sides and compare |
| extra FH load in the SRS slot | SRS is periodic (20-80 ms), not per-slot; measure with existing FH load probes |
| Cat-A regression | knob default OFF + Cat-A control after every change |
| scope creep into MU pairing | out of scope — see `SRS_WORK_SCOPE.md` |

## 7. Sequencing

**S1 → S2 → S5** (DU can receive) **→ S3 → S4** (RU can send) **→ S6 → verify**.

Do the DU side first: with S1/S2/S5 in place and the RU silent, rung 1 fails cleanly with a known
cause. Doing the RU first means transmitting into a DU that cannot receive, and rung 1 fails
ambiguously.

**Not in scope:** fixing Track A's `h_eff` reconstruction. Track B deletes it
(`CATB_TRACKB_SCOPE.md` B3), and the shared pieces it would have validated — RU combining, BFW
transport, the MMSE solve — are already validated independently.
