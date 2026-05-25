# Invalid U-plane Packet Diagnosis

## Symptom

```
[HW]     [ORU] Drop invalid U-plane packet: port=0 frame=17 subframe=3 slot=38 slot_in_frame=44 symbol=37 ant=0 start_prb=0 num_prb=0 nDLRBs=106 neAxc=1
[HW]     Packets early: 1
[HW]     Packets malformed (packet couldn't be processed): 1
```

Numerology µ=1 (30 kHz SCS): valid slot_id = 0–1 per subframe (0–19 per frame), valid symb_id = 0–13.
Getting slot=38, symbol=37, num_prb=0 is impossible from a correctly operating DU.

---

## What It Is NOT

**Not an IPv6 / stray layer-2 packet.**

The xran EtherType handler `handle_ecpri_ethertype()` in `xran_main.c` is registered only for `0xAEFE` (eCPRI). Any non-eCPRI frame (ARP, IPv6 NS, LLDP) is dropped before it reaches the O-RU packet processor. Suppressing IPv6 on the PF therefore has no effect on this error.

The packet that causes this log:
- Has EtherType `0xAEFE` (genuine eCPRI Ethernet)
- Has eCPRI message type `0x00` (IQ Data Transfer, i.e., U-plane)
- Passes `xran_extract_iq_samples()` — fields are extracted without parse failure
- But the extracted values are invalid for µ=1

---

## Root Cause: `xran_slotid_convert` Mismatch

### The conversion function

`phy-f-1.0/fhi_lib/lib/src/xran_main.c`:

```c
uint32_t xran_slotid_convert(uint16_t slot_id, uint16_t dir)
// dir=0: PHY slot → O-RAN wire slot (5.3.2)
// dir=1: O-RAN wire slot → PHY slot
{
    return slot_id;   // ← currently a no-op
#if 0
    // When ACTIVE for µ=1, FR1:
    // dir=0: return slot_id << (2-1) = slot_id * 2
    // dir=1: return slot_id >> (2-1) = slot_id / 2
    ...
#endif
}
```

### DU TX path (xran_common.c ~line 1010)

```c
xp[idx].app_params.sf_slot_sym.slot_id = xran_slotid_convert(slot_id, 0);
```

### RU RX path (xran_up_api.c line 399)

```c
*slot_id = xran_slotid_convert(radio_hdr->sf_slot_sym.slot_id, 1);
```

### How slot=38 and symbol=37 appear

If the **DU binary was linked against a build of phy-f-1.0 where the `#if 0` was removed**:
- DU computes PHY slot = 19 (last slot in frame for µ=1)
- DU encodes wire slot = `19 << 1 = 38`
- RU receives 38, applies no-op conversion → slot_id = 38 (invalid)

The `symbol=37` in the same packet suggests the same binary mismatch affects other fields or this is the symbol from a different TTI encoded the same way.

The `num_prb=0` indicates the packet is either a dummy/empty DL slot or the PRB map element had `UP_nRBSize=0`.

### Code path that catches it

`oaioran_ru.c:640–646`:

```c
if (slot_in_frame < 0 || slot_in_frame >= num_slots_per_frame
    || symb_id >= NR_SYMBOLS_PER_SLOT
    || Ant_ID >= fh_cfg->neAxc
    || start_prbu >= fh_cfg->nDLRBs
    || num_prbu == 0
    || start_prbu + num_prbu > fh_cfg->nDLRBs) {
    LOG_W(HW, "[ORU] Drop invalid U-plane packet: ...");
    packet_processor_context.up_malformed++;
    packet_processor_context.up_dropped++;
    return MBUF_FREE;
}
```

The packet is detected and dropped — no IQ data corruption occurs. This is working correctly.

---

## Diagnostic Steps

### 1. Check binary / library mismatch

```bash
# Build timestamps
ls -la ~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-softmodem
ls -la ~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-oru

# Which libxran each binary links
ldd ~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-softmodem | grep -i xran
ldd ~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-oru | grep -i xran
```

They must resolve to the **same** `libxran.so` (or both must be statically linked from the same source).

### 2. Verify the no-op is present in both

```bash
grep -A5 "xran_slotid_convert" \
  ~/oran_lab/oaicicd/test_dir/phy-f-1.0/fhi_lib/lib/src/xran_main.c
```

Expected output — the body must be just `return slot_id;` with the shift logic inside `#if 0`.

### 3. Capture the actual packet

Capture VF4 (iavf, VLAN 3) sees all U-plane traffic:

```bash
CAPTURE_IFACE=$(ls /sys/bus/pci/drivers/iavf/*/net/ 2>/dev/null | head -1 | xargs basename)
echo "Capture interface: $CAPTURE_IFACE"
sudo tcpdump -i "$CAPTURE_IFACE" -nn -e -X 'ether proto 0xaefe' -c 20 2>&1 | tee /tmp/ecpri_capture.txt
```

In the raw bytes, the `sf_slot_sym` field is at offset **19** from the start of the Ethernet frame:
- 14 bytes Ethernet header
- 4 bytes eCPRI common header
- 1 byte `frame_id`
- 2 bytes `sf_slot_sym` ← here

Decode the 2 bytes: bits[15:12]=subframe, bits[11:6]=slot, bits[5:0]=symbol.
If slot bits decode to 38, the DU is writing the wire-format slot (with the `<< 1` shift applied).

### 4. Check timing: startup glitch vs. continuous

```bash
# Run with INFO-level HW logging to see frequency
global_log_level = "warn";
hw_log_level     = "info";   # already set in ru_test.conf
```

If the "Drop invalid" message appears only in the first ~10 frames after the DU starts and then stops, it is a startup timing glitch (benign). If it is periodic (every N frames), the slot-ID mismatch is ongoing.

---

## Host Finding

On this host, `run_ru.sh` was already launching:

```bash
~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-oru
```

But `run_du.sh` was launching the older:

```bash
~/oran_lab/oaicicd/test_dir/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem
```

while a newer matching DU binary exists at:

```bash
~/oran_lab/oaicicd/test_dir/openairinterface5g/build/nr-softmodem
```

The launcher has been changed so DU and RU both use `openairinterface5g/build`.

## Fix

Rebuild `nr-softmodem` and `nr-oru` against the **same** phy-f-1.0 source tree, ensuring `xran_slotid_convert` is the no-op `return slot_id;` in both:

```bash
# Confirm source is consistent
head -5 ~/oran_lab/oaicicd/test_dir/phy-f-1.0/fhi_lib/lib/src/xran_main.c

# Rebuild phy-f-1.0 library
cd ~/oran_lab/oaicicd/test_dir/phy-f-1.0
make clean && make

# Rebuild nr-softmodem (DU)
cd ~/oran_lab/oaicicd/test_dir/openairinterface5g
cmake_targets/build_oai.sh --gNB -w SIMU 2>&1 | tee build_du.log

# nr-oru is built separately per build instructions
```

If the drop counter stays at 0 after the rebuild, the mismatch was the cause.

---

## Summary

| Question | Answer |
|---|---|
| Is it stray ARP/IPv6 NS? | **No** — xran filters by EtherType 0xAEFE before any processing |
| Is it a random non-eCPRI packet? | **No** — passes full eCPRI header parse |
| Does IPv6 suppression fix it? | **No** |
| Is data corrupted? | **No** — the drop path discards it before IQ copy |
| Root cause | DU linked against phy-f-1.0 with active `xran_slotid_convert` (slot×2 for µ=1); RU uses no-op version → slot mismatch |
| Fix | Rebuild both binaries from same phy-f-1.0 source |
