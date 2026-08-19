# O-RU SRS — development plan, point by point

2026-08-19. Implementation detail for `CATB_ORU_SRS_SCOPE.md` rev 2.
Order is dependency order. **Do the DU side first** (S1-S3) so the first failure has a known cause.

Templates throughout: **PRACH** is the existing, working second-eAxC stream. Copy it.

---

## PHASE 1 — DU can receive (S1-S3)

### S1. Add the SRS buffer set
**File:** `radio/fhi_72/oran-init.h`, struct `oran_buf_list` (line ~46-60)

1.1 Add next to `prachdst` / `prachdstdecomp`:
```c
struct xran_buffer_list srsdst[XRAN_MAX_ANT_ARRAY_ELM_NR][XRAN_N_FE_BUF_LEN];
struct xran_buffer_list srsdstcp[XRAN_MAX_ANT_ARRAY_ELM_NR][XRAN_N_FE_BUF_LEN];
```
**CAUTION — different dimension.** `xran_5g_srs_req()` takes
`[XRAN_MAX_ANT_ARRAY_ELM_NR][XRAN_N_FE_BUF_LEN]`, and `XRAN_MAX_ANT_ARRAY_ELM_NR = 64`, not
`XRAN_MAX_ANTENNA_NR = 16` used by PRACH/PUSCH. Getting this wrong is a silent stack/heap overrun.
We only populate the first `ru->nb_rx` (16) entries; the rest stay zeroed.

1.2 Add the backing storage in the same struct's `bufs` sub-struct, mirroring how
`bufs.prach` / `bufs.prachdecomp` are declared. Size per antenna per slot:
`XRAN_NUM_OF_SYMBOL_PER_SLOT * ofdm_symbol_size * sizeof(c16_t)`.

### S2. Allocate + register
**File:** `radio/fhi_72/oran-init.c` (~line 440-480)

2.1 Allocate in the same loop that fills `prachdst[a][j]` (~line 440-454):
```c
bl->srsdst[a][j].pBuffers = &bl->bufs.srs[a][j][0];
// per symbol k: fb->pData = <backing storage>, fb->nElementLenInBytes, fb->nNumberOfElements
```
Copy the PRACH loop verbatim and change names — including `nElementLenInBytes` and
`nNumberOfElements`, which PRACH sets and are easy to miss.

2.2 Add the pointer arrays next to `prach[a][j]` / `prachdecomp[a][j]` (~line 456-473):
```c
struct xran_buffer_list *srs[XRAN_MAX_ANT_ARRAY_ELM_NR][XRAN_N_FE_BUF_LEN];
struct xran_buffer_list *srscp[XRAN_MAX_ANT_ARRAY_ELM_NR][XRAN_N_FE_BUF_LEN];
...
srs[a][j]   = &bl->srsdst[a][j];
srscp[a][j] = &bl->srsdstcp[a][j];
```

2.3 Register, immediately after the PRACH call at **line 478**:
```c
xran_5g_srs_req(pi->instanceHandle, srs, srscp,
                oai_xran_fh_rx_srs_callback, &portInstances->srs_tag);
```

2.4 Add `srs_tag` to the port-instances struct beside `prach_tag` / `pusch_tag`.

2.5 Write `oai_xran_fh_rx_srs_callback()` mirroring `oai_xran_fh_rx_prach_callback()`.

**DO NOT alias buffers.** `oran-init.c:406` records that aliasing `srccp/dstcp` for the BFW maps
already cost this project runs. `srsdst` must be dedicated.

### S3. DU read path
**File:** `radio/fhi_72/oaioran.c`

3.1 Write `read_srs_data(ru, frame, slot)` mirroring `read_prach_data()` (called at line 901).
3.2 Call it beside `read_prach_data()` at **line 901**.
3.3 It must land samples in `ru->rxdataF[ant]` at:
```
offset = slot_size * (slot % RU_RX_SLOT_DEPTH) + sym * ofdm_symbol_size
```
matching the PUSCH demux at lines 906-930 — that offset convention is the entire compatibility
surface with `nr_get_srs_signal()` (`srs_rx.c:86`).
3.4 Decompress per `ru_conf.compMeth` / `iqWidth`, exactly as the PUSCH path does.

**Checkpoint A:** build, run with the RU still silent. Expect `rx_srs_packets` = 0 and
no crash. Proves the DU side is wired without changing behaviour.

---

## PHASE 2 — RU can send (S4-S5)

### S4. `xran_oru_send_srs()`
**File:** `radio/fhi_72/oaioran_ru.c`

4.1 Copy `xran_oru_send_prach()` wholesale; rename.
4.2 Change the eAxC resolution to the SRS offset:
```c
int vf_id = xran_map_ecpriPcid_to_vf(gxran_handle, XRAN_DIR_UL, 0,
                                     aarx + fh_cfg->srs_conf.eAxC_offset);
```
4.3 Keep per-antenna, **no beamforming** — SRS exists to give the 16-antenna channel.
4.4 Compress per `ru_conf`, same as PRACH.
4.5 Send with `xran_ethdi_mbuf_send(mbuf, ETHER_TYPE_ECPRI, vf_id)`.
4.6 Gate on `ORU_SRS_TX=1`, **default OFF**, resolved once into a static (the pattern every knob
in this tree uses).

Second reference if the section headers are unclear: xran's own O-RU emulation,
`phy-f-1.0/fhi_lib/app/src/app_io_fh_xran.c` `p_tx_srs_play_buffer` (~L1474). Note
`xran_srs_config.slot / ndm_offset / ndm_txduration` are commented *"for O-RU emulation"*.

### S5. Drive it from the slot loop
5.1 Add the SRS-slot branch where `xran_oru_send_pusch()` is driven.
5.2 Take the slot and symbol set from `fh_cfg->srs_conf` (populated by `xran_init_srs()`,
`xran_main.c:215`). **Never hardcode** — the TDD-period lesson from §19/§20.

---

## PHASE 3 — config + bring-up (S6)

6.1 `du_test.conf`: `do_SRS = 1`
6.2 Set `srs_conf.eAxC_offset` so it does not collide with PUSCH (0..15) or PRACH ranges.
    **Assert non-overlap at init** — a silent collision looks like corrupt PUSCH.
6.3 Add `ORU_SRS_TX` to the `run_du.sh` **and** `run_ru.sh` env allowlists.
    An unlisted variable is dropped **silently** — this trap has bitten 3x
    (`OAI_CATB_SU_BFW` / `OAI_CATB_PUB_IRC` were inert for two commits).
6.4 Rebuild all four artifacts and check mtimes: `nr-softmodem`, `nr-oru`,
    `liboran_fhlib_5g.so`, `libvrtsim.so`. `oran-init.h` is a shared header — a stale `.so`
    against a changed struct is the §7 ABI trap.

---

## VERIFICATION LADDER — stop at the first rung that fails

| # | rung | signal |
|---|---|---|
| A | DU wired, RU silent | builds, runs, `rx_srs_packets` = 0, Cat-A unaffected |
| 1 | packets arrive | `rx_srs_packets` **non-zero** in `[FH RXCLS]` |
| 2 | packets parse | `nr_get_srs_signal()` returns `>= 0` |
| 3 | estimation runs | `nr_srs_channel_estimation()` reached (`phy_procedures_nr_gNB.c:1010`) |
| 4 | MAC receives | `handle_nr_srs_measurements()` fires |
| 5 | **CORRECTNESS** | SRS per-antenna `\|H_a\|` **matches PUSCH-DMRS `\|H_a\|` same slot, within noise** — reuse `[CATB HSUM]` |
| 6 | no regression | Cat-A control ~174 Mbps / MCS 28,28 with `ORU_SRS_TX=0` |

Rung 5 is the acceptance test. Rungs 1-4 only prove plumbing.

---

## RIG DISCIPLINE (non-negotiable, all learned the hard way)

- **Process check immediately before any destructive op**, not once at the top:
  `pgrep -a -x 'nr-or[u]'; pgrep -a -x 'nr-softmode[m]'` (brackets avoid self-match).
- **Never put `nr-softmodem` / `nr-oru` / `nr-uesoftmodem` / `ul_saturate.py` in the same command
  line that launches the harness** — its preflight `pkill -9 -f` kills your own shell. Symptom:
  empty log dir, exit 1, no stderr. Cost ~6 runs.
- **Hugepage gate:** `HugePages_Free: 8192` before launching. `find -delete` cannot reclaim mapped
  entries; cycle `nr_hugepages` 0 then 8192.
- **Cat-A control is the rig check** — run it the moment behaviour gets odd. Both documented
  preflights (`no SMF candidate` count, ~20 dB PRACH) are blind to the stale-CN failure mode.
- **N >= 3** per measurement. Run-to-run variance has spanned 2x on identical configs.
- **Never `timeout ... | tail`** — `tail` buffers to EOF and dies with the pipeline, so a healthy
  run looks like instant silent death. Redirect to a file.

---

## ESTIMATE / RISK

| item | size | risk |
|---|---|---|
| S1-S2 buffers + registration | small | dimension mismatch (64 vs 16); aliasing |
| S3 DU read path | **medium** | offset convention must match `srs_rx.c:86` exactly |
| S4-S5 RU transmit | medium | PRACH is a close template; section headers are the fiddly part |
| S6 config | small | eAxC collision; allowlist |

**Biggest unknown: S3.** Everything else has a working analogue to copy line-for-line.

---

## START HERE — next session

**Read in this order:** this file → `CATB_ORU_SRS_SCOPE.md` (why/contract) →
`CATB_TRACKB_SCOPE.md` (what it unlocks) → `CATB_STATUS_AND_DEBUG_NOTES.md` (state + retractions).
`CATA_CONTROL_RUNBOOK.md` for the rig check.

**Decision already made:** go Track B. **Do NOT fix Track A's `h_eff` collapse** — Track B deletes
that code (`CATB_TRACKB_SCOPE.md` B3), and the pieces it would have validated (RU combining, BFW
transport, MMSE solve) are already validated independently. Cat-B stays at 0 Mbps until SRS works;
that is expected and accepted.

**Tree state**
| repo | branch | note |
|---|---|---|
| oran_lab | `catb-srs-ru-mmse` | current |
| openairinterface5g | `catb-instrumentation` | current. **`.gitmodules` says `compression-plus-timing-fix` — STALE, the two diverged (ahead 100 / behind 116)** |
| phy-f-1.0 | `xran-timescale` | pristine |

All history was rewritten 2026-08-19 to author *Jesse Chiu, University of Washington, Seattle*.
**Force-push to `origin` (oran_lab) and `bck` (OAI) is still PENDING** — run it before any new work
or the remotes stay on the old hashes. Rollback: `refs/original/refs/heads/*`.

**First action:** S1 (add `srsdst` to `oran_buf_list_t`). Nothing to measure until checkpoint A.

**Do NOT re-investigate** (settled, with evidence in `CATB_STATUS_AND_DEBUG_NOTES.md` §5):
wideband BFW · conjugation convention · antenna mapping · weight degeneracy · quantisation ·
Gram conditioning · ring mapping · coverage · AGC. All refuted by measurement.
