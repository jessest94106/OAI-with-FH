# Fix: PRACH C-plane Timing Mismatch (UE MSG1 Failure)

## Problem

UE MSG1 (PRACH Random Access Request) consistently fails. The DU never sends a RAR because it never receives the full PRACH preamble from the RU.

### Root Cause

The O-RAN 7.2 fronthaul requires the DU to send a C-plane section type 3 packet to the RU before each PRACH slot. The RU caches this config in `prach_config_by_frame_slot[ant][frame&0xff][slot]` and uses it in `xran_oru_send_prach()` to forward PRACH IQ data to the DU. If the cache entry is missing, `xran_oru_send_prach()` returns early with a warning and the PRACH symbols are silently dropped.

The timing mismatch with `T1a_max_cp_ul = 429µs`:

```
delay_cp_ul = slot_interval - T1a_max_cp_ul = 500 - 429 = 71µs
sym_cp_ul   = floor(71 * 14 / 500) + 1 = 2
offset_num_slots_cp_ul = 0
```

The DU fires `tx_cp_ul_cb` at **symbol 2** (t ≈ 71µs) of the PRACH slot (slot 19), sending the C-plane for the **current** slot. Meanwhile the RU's `oru_south_read_thread` calls `xran_oru_send_prach()` at:

- symbol 0 → t = 0µs    → cache empty → dropped
- symbol 1 → t = 35.7µs → cache empty → dropped
- symbol 2 → t = 71.4µs → C-plane *just* arrived, race condition

PRACH format B4 (`prach_config_index=159`) requires 12 consecutive symbols. Losing symbols 0–1 breaks preamble detection entirely.

## Fix

**File:** `/home/jesse/oran_lab/du_test.conf`

```diff
-    T1a_cp_ul = (285, 429);
+    T1a_cp_ul = (285, 535);
```

### Why 535µs

With `T1a_max_cp_ul = 535µs > 500µs` (one slot interval), xran's `xran_timing_create_cbs()` in `xran_cb_proc.c` computes:

```c
// ul_delay_offset starts at 500µs; 535 > 500 → loop once
offset_num_slots_cp_ul = 1
delay_cp_ul = 1000 - 535 = 465µs
sym_cp_ul   = floor(465 * 14 / 500) + 1 = 14 → 14 % 14 = 0
```

Result: `tx_cp_ul_cb` fires at **symbol 0 of slot 18**, sending a C-plane packet whose header encodes **frame F, subframe 9, slot 1** (= slot 19 of frame F). The RU receives it via SR-IOV loopback in ~5–50µs and caches it immediately in `process_ru_cplane()` (no timing window enforcement on the RU side). The cache is populated ~450µs before slot 19 begins, so all 12 PRACH symbols are forwarded successfully.

## No Recompile Required

This is a config-only change. `T1a_cp_ul` is parsed at DU startup by `oran-config.c` and passed directly to xran as `fh_cfg.T1a_max_cp_ul`. Restart the DU (and RU) to apply.

## Related Background

| Parameter | File | Value | Role |
|---|---|---|---|
| `T1a_cp_ul` | `du_test.conf` | **(285, 535)** ← changed | DU UL C-plane send timing |
| `T2a_up` | `ru_test.conf` | `(200, 1200)` | RU UL U-plane acceptance window (unchanged) |
| `callbacks_per_slot` | `oran-init.c` | `14` | RU consumer wakeup rate (fixed earlier, was 2) |
| PRACH config index | both confs | `159` | Format B4, subframe 9, 12 symbols |

---

# Fix 2 & 3: PRACH C-plane Never Sent + Slot Overflow on RU (Root Causes)

## Problem

Even after the T1a_cp_ul timing fix, RAR still fails. Two code bugs prevent PRACH C-plane from ever reaching the RU.

### Bug A — `tx_cp_ul_cb`: C-plane packet built but never transmitted

**File:** `phy-f-1.0/fhi_lib/lib/src/xran_main.c:1401`

`generate_cpmsg_prach()` internally calls `xran_prepare_ctrl_pkt()` which returns a **positive byte count** on success (not `XRAN_STATUS_SUCCESS = 0`). The caller checks:
```c
if (ret == XRAN_STATUS_SUCCESS)   // = (ret == 0) — NEVER true for success
    send_cpmsg(...);
```
So `send_cpmsg()` is never reached. The C-plane packet is built and the mbuf allocated, but never placed in the TX ring.

**Fix:**
```diff
-if (ret == XRAN_STATUS_SUCCESS)
+if (ret >= 0)
```

### Bug B — `process_ru_cplane()`: slot index overflows bounds check

**File:** `openairinterface5g/radio/fhi_72/oaioran_ru.c:700`

The section type 3 C-plane header's `frameStructure.uScs` encodes the **PRACH SCS** (= 14 for Format B4 / XRAN_FILTERINDEX_PRACH_3), not the NR numerology µ. Using it to compute the UL slot:
```c
int mu = hdr->frameStructure.uScs;  // = 14, not 1
int slot = slotId + subframeId * (1 << mu);  // = 1 + 9×16384 = 147457
// → slot >= PRACH_SLOTS_PER_FRAME(20) → LOG_W + return without caching
```

**Fix:**
```diff
-int mu = hdr->frameStructure.uScs;
+int mu = fh_cfg->frame_conf.nNumerology;
```

## Rebuild

After both patches:
```bash
# Rebuild libxran.so (contains tx_cp_ul_cb)
TEST_DIR=/home/jesse/oran_lab/oaicicd/test_dir
DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
cd $TEST_DIR/phy-f-1.0/fhi_lib/lib
TARGET=x86 WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$DPDK_INST XRAN_DIR=$TEST_DIR/phy-f-1.0/fhi_lib make XRAN_LIB_SO=1 -j$(nproc)

# Rebuild liboran_fhlib_5g.so (contains process_ru_cplane)
cd $TEST_DIR/openairinterface5g/build
ninja liboran_fhlib_5g.so
```

## Relevant Code Paths

- `xran_cb_proc.c:233–244` — computes `offset_num_slots_cp_ul` and `sym_cp_ul`
- `xran_main.c:1291–1407` — `tx_cp_ul_cb()` sends PRACH C-plane gated by `first_call`
- `oaioran_ru.c:684–724` — `process_ru_cplane()` populates PRACH cache (no timing gate)
- `oaioran_ru.c:883–930` — `xran_oru_send_prach()` checks cache before forwarding
- `nr-oru.c:477–522` — `oru_south_read_thread()` calls `xran_oru_send_prach` per symbol
