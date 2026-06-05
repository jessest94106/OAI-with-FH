# OAI O-RAN 7.2 Lab — End-to-End Debugging Technical Report

**System:** OpenAirInterface 5G NR — split DU + O-RU + UE on a single host
**Date span:** 2026-05-26 → 2026-06-01
**Author:** Jesse

**Summary.** This report documents the bring-up and debugging of an OpenAirInterface 5G NR
system running the O-RAN 7.2 functional split (DU + O-RU + UE) on a single host, where the
fronthaul is carried over real DPDK/SR-IOV between NIC virtual functions and the radio
channel is emulated in shared memory (vrtsim). It follows the system from a state in which
the UE could not synchronize at all, through a chain of fronthaul control- and user-plane
defects that produced zero uplink throughput, the compression-header misalignment that
destabilized the uncompressed (iq16) path, and a stalled core-network function that blocked
PDU-session establishment, up to a working end-to-end link. It then explains why uplink
goodput settles near 5 Mbps and why the cell is effectively limited to 10 MHz, and presents
measured results for every experimental axis exercised — compression width, antenna count,
bandwidth, receive SNR, fronthaul latency, and mobility — reporting the flat, noisy, and
cliff-shaped outcomes as plainly as the clean ones. All throughput figures are server-side
iperf3 measurements taken inside the UPF network namespace; the measurement method is
described in §3.3.

---

## 0. Test Architecture (the thing being debugged)

```
 ┌────────────────┐   FH: O-RAN 7.2 split        ┌────────────┐   "air" (vrtsim       ┌────────────────┐
 │  DU             │   eCPRI/xran over DPDK       │  O-RU      │    shared-memory)     │  UE            │
 │  nr-softmodem   │──── SR-IOV VF↔VF, 2 VLANs ──▶│  nr-oru    │──── chanmod / IQ ────▶│  nr-uesoftmodem │
 │  (PHY/MAC)      │◀─── 10G-class embedded ──────│  (RU PHY)  │◀─── passthrough ──────│                │
 └────────┬───────┘     switch (VEB)              └────────────┘                       └────────────────┘
          │ NGAP / GTP-U
          ▼
   ┌──────────────┐
   │  OAI 5GC     │  (docker-compose: AMF / SMF / UPF / NRF / MySQL)
   └──────────────┘
```

Two distinct interfaces, repeatedly conflated during debugging — keep them separate:

| Interface | Path | Medium | Bug class found here |
|---|---|---|---|
| **Fronthaul (FH)** | DU ↔ RU | O-RAN 7.2 eCPRI/xran over DPDK SR-IOV | C-plane timing, slot-ID, U-plane buffer reset, compression header |
| **Air** | RU ↔ UE | vrtsim shared-memory channel | chanmod realtime, SNR, mobility |

**Hardware / cell fundamentals (these define the limits later):**

- **NIC:** Intel X710 (i40e), PF `eno1np0` (`0000:05:00.0`), PF link **DOWN** — loopback rides
  the card's embedded switch (VEB), no cable needed. 5 VFs on the PF:
  - vf0 `06:02.0` / vf1 `06:02.1` = **RU egress** (UL U-plane RU→DU), VLAN 3 / 4
  - vf2 `06:02.2` / vf3 `06:02.3` = **DU egress** (DL DU→RU), VLAN 3 / 4
- **Cell:** 24 PRB, numerology µ1 (30 kHz SCS) → **10 MHz**, sample rate **fs = 15.36 Msps**.
  Band n77, fc = 4049.76 MHz. This 24-PRB / 10-MHz figure is the answer to the final question.
- **Build location (a trap that cost many runs):** the lab runs binaries from
  `oaicicd/test_dir/openairinterface5g/**build/**`. The FH code (`oaioran.c` = DU-RX,
  `oaioran_ru.c` = RU-TX, `oai_bfp_compression.c`, `oran-config.c`) compiles into a
  **runtime-dlopen'd shared library `liboran_fhlib_5g.so`** — *not* into the
  `nr-softmodem`/`nr-oru` executables. **Rebuilding the executables does not pick up FH
  changes; you must `ninja oran_fhlib_5g`.** Several "fixes had no effect" episodes were
  actually edits to a library that was never rebuilt.

---

## 1. Before sync — the UE could not synchronize

### 1.1 Binary / library mismatch → "Drop invalid U-plane packet"

**Symptom**
```
[ORU] Drop invalid U-plane packet: ... slot=38 ... symbol=37 num_prb=0 nDLRBs=106
Packets early: 1 / Packets malformed: 1
```
For µ1, valid slot = 0–19 and symbol = 0–13. `slot=38`, `symbol=37` are impossible from a
correct DU.

**Root cause.** It was *not* a stray ARP/IPv6 frame — xran only accepts EtherType `0xAEFE`
(eCPRI) and the packet parsed cleanly. The real cause was a **DU/RU binary–library
mismatch**:

- `run_ru.sh` launched the new `build/nr-oru`, but `run_du.sh` launched the **old**
  `cmake_targets/ran_build/build/nr-softmodem`.
- `xran_slotid_convert()` (`phy-f-1.0/.../xran_main.c`) is a **no-op** (`return slot_id;`)
  in the current source, but the old DU binary was linked against a build where the µ1
  shift (`slot_id << 1`) was active. DU encoded wire slot `19 << 1 = 38`; the RU applied
  the no-op and read 38 → invalid → dropped.

It was confirmed *not* to be a stray ARP/IPv6 frame: xran's `handle_ecpri_ethertype()`
only dispatches EtherType `0xAEFE`, so any non-eCPRI frame is dropped before the packet
processor, and the offending packet passed the full eCPRI header parse. The mismatch path is
`xran_slotid_convert(slot_id, 0)` on the DU TX side (`xran_common.c`) vs.
`xran_slotid_convert(.., 1)` on the RU RX side (`xran_up_api.c`): if only one binary has the
µ1 shift compiled in, the wire slot and the decoded slot disagree.

**Fix.** Point **both** launchers at `openairinterface5g/build/`, and rebuild DU + RU
against the same `phy-f-1.0` source so `xran_slotid_convert` is the no-op in both. The drop
counter (`up_malformed`/`up_dropped`, bounds-checked at `oaioran_ru.c:640`) went to 0.

### 1.2 PRACH MSG1 never completed — three stacked bugs

After sync acquisition the UE sent PRACH (MSG1) but the DU never returned a RAR. The DU
never received the full PRACH preamble from the RU. Three independent bugs, all on the FH
C-plane path:

**(A) C-plane timing window — `T1a_cp_ul` too tight.**
The DU must send a C-plane *section type 3* packet to the RU **before** each PRACH slot;
the RU caches it in `prach_config_by_frame_slot[...]` and uses it in
`xran_oru_send_prach()`. With `T1a_max_cp_ul = 429µs`:
```
delay_cp_ul = 500 − 429 = 71µs  → C-plane fired at symbol 2 of the PRACH slot
```
The RU's read thread hit symbols 0 and 1 with an **empty cache** → those PRACH symbols
dropped. PRACH format B4 (`prach_config_index=159`) needs **12 consecutive symbols**;
losing symbols 0–1 kills detection.
**Fix:** `T1a_cp_ul = (285, 535)` in `du_test.conf`. With `T1a_max > 500µs` xran wraps one
slot earlier (`offset_num_slots_cp_ul = 1`) and fires the C-plane at **symbol 0 of slot 18**,
populating the cache ~450µs before slot 19. Config-only, no recompile.

**(B) C-plane built but never transmitted.**
`tx_cp_ul_cb()` (`xran_main.c:1401`) checked
```c
if (ret == XRAN_STATUS_SUCCESS)   // == 0
    send_cpmsg(...);
```
but `generate_cpmsg_prach()` returns a **positive byte count** on success, so
`send_cpmsg()` was never reached — the packet was built, the mbuf allocated, and then
discarded. **Fix:** `if (ret >= 0)`.

**(C) Slot index overflow in the RU cache write.**
`process_ru_cplane()` (`oaioran_ru.c:700`) read the numerology from the section-type-3
header's `frameStructure.uScs`, which for Format B4 encodes the **PRACH SCS (=14)**, not
µ:
```c
int mu = hdr->frameStructure.uScs;            // 14, not 1
int slot = slotId + subframeId*(1<<mu);       // 1 + 9*16384 = 147457  → out of bounds
```
so the entry was never cached. **Fix:** `int mu = fh_cfg->frame_conf.nNumerology;`

Also fixed earlier: `callbacks_per_slot` in `oran-init.c` was `2`, raised to **14** (one RU
consumer wakeup per symbol).

After (A)+(B)+(C): PRACH forwarded intact, RAR returned, RA completed. Rebuild scope:
`libxran.so` (A/B live in xran) **and** `liboran_fhlib_5g.so` (C).

### 1.3 Residual: flaky *initial* DL sync (warmup transient)

Even once correct, the UE logs 0–200 `synch Failed` before the first lock, varying per
run; **once locked it stays locked** for the whole session. This is a startup/timing
alignment transient (worse with iq9 than iq16). Handled operationally with retry-to-attach
loops, not a code bug. Commit `0e9b835` ("sync success") on the lab repo marks this point.

---

## 2. Why there was no UL throughput (zero / 99.9 % retransmission)

This was the central bug. After sync + RA, the link was up but **UL goodput was
effectively zero**, with the UE MAC reporting ~99.9 % HARQ retransmission
(`UL harq: ~719/718`) at a healthy ~34 dB SNR.

### 2.1 Root cause — the UL U-plane buffer reset wiped early symbols

The RU streams UL U-plane **symbol-by-symbol in near real time**. An uncommitted line in
`oai_xran_fh_rx_callback` (`radio/fhi_72/oaioran.c`) reset the **next** ring buffer,
`(tti + 1) % 20`, from the mid-slot (`rx_sym == 7`) callback. But the next slot's first
U-plane packets **arrive before that mid-slot callback fires**, so resetting `(tti+1)`'s
`nSecDesc` cleared symbols 0–8 *after* they had already landed. Only the last ~5 symbols of
each slot survived.

**Proof.** A temporary `[UL SYMPROBE]` in `xran_fh_rx_read_slot` logged
`present=5/14 mask=00000000011111` for full UL slots (only syms 9–13) and `4/4` for the
mixed slot — deterministic, not random. A separate `[FH DROP]` probe confirmed xran was
**not** dropping (`Rx_pkt_dupl=0`, `Rx_on_time` huge) — the symbols reached the buffer; the
reset wiped them. The LDPC decoder corroborated: large UL TBs decoded only on HARQ round 3
(rv3), with `ulsch_llr[0..3]=0,0,0,0` (the missing early symbols), partial REs accumulating
across rounds.

**Fix.** Reset `(tti + XRAN_N_FE_BUF_LEN/2) % 20` (= **tti+10**) — half a ring away, cleared
long before its own slot is filled or read, never touching the active fill/read window:
```c
// oaioran.c, oai_xran_fh_rx_callback (committed in 37b55fa535)
- reset_buffer((tti + 1) % 20);
+ reset_buffer((tti + XRAN_N_FE_BUF_LEN/2) % 20);   // tti+10
```
Result: `present=14/14 mask=11111111111111`, **all HARQ round 0**, `UL harq: 845/0` =
**zero retransmissions**. NAS registration (Auth / SecurityMode / Registration Accept —
which needs reliable bidirectional NAS) now completed. Lab commit `c10a7c0`
("phy fix for correct high UL throughput").

### 2.2 The iq16 sibling bug — PUSCH compression-header offset

With UL flowing, **iq9 (BFP-compressed) worked but iq16 (uncompressed) had wildly unstable
SNR (−8.5 to +39 dB vs. a stable 63 dB for iq9).**

**Root cause.** `xran_oru_send_pusch()` (`oaioran_ru.c`) **unconditionally** wrote a 2-byte
`data_section_compression_hdr` before the IQ payload — *even when `compMeth == NONE`
(iq16)*. The DU's xran reader (`xran_common.c:322`) computes
`iq_offset = ecpri + radio_app + data_section` for `NONE` (no compression header), so it
read the 2 zero header bytes as the **first IQ sample**, shifting every UL sample by one
position. For iq9/BFP, `xran_common.c` adds `compr_size` to `iq_offset`, so iq9 was always
aligned — which is why only iq16 failed.

**Fix (commit `47dcaef44b`).** Gate the header write:
`use_comp_hdr = (compMeth != NONE)`; for `NONE`, `iq_data_start = data_section_hdr + 1`.
Also fixed a **BFP mbuf under-allocation** (2 bytes short, truncating the last 2 bytes of
each BFP packet). Note: iq16's truncation was masked in iq9 runs by
`ul_prbblacklist = "0,1,2,3,20,21,22,23"`, which hides the edge PRBs where the truncation
landed.

Earlier compression history (lab repo `6a6ad68` "compression success", OAI
`40eaf33c9c`/`dae942c616`): BFP compression was implemented without AVX512 and needed
"extra bytes" added to the compression header — the precursor to the `47dcaef44b` fix.

### 2.3 The CN side — PDU Session Establishment reject

With the radio/FH UL path fixed, the UE attached at RRC but the **PDU session was
rejected** (`FGS_PDU_SESSION_ESTABLISHMENT_REJ`): the UE got no IP, no `oaitun_ue1`.

**Root cause.** The **SMF had hung** — last log ~31 h earlier, zero NRF heartbeats; the
container was "healthy" but the app was deadlocked (likely on a PFCP recv from the UPF).
Consequently the NRF had **no SMF registered**
(`.../nnrf-nfm/v1/nf-instances?nf-type=SMF → item:[]`), so the AMF
(`enable_smf_selection: yes`) logged *"No SMF is available for this PDU session / Could not
find Nsmf_PDUSession URI"*.

**Fix.** Full CN restart (a bare SMF restart fixed discovery but the first session still
rejected with "empty QFI list" from stale UPF/N4 state):
```bash
cd ~/oran_lab/oai-cn5g && docker-compose down && docker-compose up -d   # v1, hyphenated
```
Config (DNN "oai", sst=1, 5QI 9, PAA pool 10.0.0.0/24) was correct all along. After
restart: AMF finds SMF, SM context created, UE gets **10.0.0.x**, `oaitun_ue1` up.

**End-to-end milestone (2026-05-30):** iq9 UL 1.325 / DL 6.082 Mbps; iq16 UL 1.325 /
DL 7.130 Mbps. From 0 → working, both compressed and uncompressed.

---

## 3. Why UL throughput was stuck at ~1.3 Mbps, then capped near 5 Mbps

End-to-end worked, but UL sat at **1.325 Mbps** — far below the ~14 Mbps the 24-PRB cell
should give. Two scheduler issues:

### 3.1 The 5-RB grant cap — `min_grant_prb`

**Root cause.** `min_grant_prb` (MACRLCs) defaults to **5** (`MACRLC_nr_paramdef.h`,
`.defintval=5`). The UE was **always scheduled `sched_inactive`**: its buffer drains every
grant, so the scheduler's estimate `B = estimated_ul_buffer − sched_ul_bytes == 0`
(`gNB_scheduler_ulsch.c:2113`), and inactive UEs get exactly `min_grant_prb` RBs
(lines ~2190/2260). So the UL grant was pinned at **5 RBs regardless of offered load**.

**Fix.** `min_grant_prb = 16;` in `du_test.conf` MACRLCs → UL grant jumped **5 → 17 RBs**.
(A "greedy-RB" hack in the `B>0` branch did nothing — that branch is never hit when the
buffer drains — and was reverted.)

### 3.2 UL-heavy TDD pattern

The default TDD pattern `D D D M U` gives only one UL slot per period. Changed to
**`D M U U U`** (1 DL + 1 mixed + 3 UL) in **both** configs:
- `du_test.conf`: `nrofDownlinkSlots 3→1`, `nrofUplinkSlots 1→3`
- `ru_test.conf`: `num_dl_slots 3→1`, `num_ul_slots 1→3`

The UE follows automatically via SIB1. UL TBs/run went ~2337 → 26000+.

**Result:** server-measured UL **≈5.05 Mbps @ 0 % loss, 17 RBs, 0 retx** (from 1.3 Mbps,
~3.9×). Lab commit `55493cb` ("reliable UDP UL throughput via server-side capture").

### 3.3 iperf measurement methodology (how UL throughput is actually measured)

Getting a *trustworthy* UL number turned out to need as much care as the radio fixes
themselves. The pitfalls below all produced wrong readings at some point, so the method is
documented in full.

**Topology of the measurement.** The data network gateway is **10.0.0.1** — the UPF's
`tun0` / DN side. The UE gets an address in `10.0.0.0/24` on `oaitun_ue1`, and the host
routes `10.0.0.0/24` via that TUN, so any traffic to `10.0.0.1` is forced over the radio
(verified with `ip route get 10.0.0.1 from <ue_ip>` → `dev oaitun_ue1 table 9999`). UL is
therefore **UE → gNB → UPF**, and the receiver of interest is the iperf3 *server* bound to
`10.0.0.1`.

```
   UE host (client)                                  UPF container netns (server)
   iperf3 -c 10.0.0.1  ──▶ oaitun_ue1 ──radio──▶ gNB ──GTP-U──▶ UPF tun0 ──▶ iperf3 -s -B 10.0.0.1
        send rate (lies)                                              received rate (truth)
```

**Pitfall 1 — wrong server bind address inflates the result ~7000×.** Pointing the client
at the *host* IP (`192.168.70.129`) instead of `10.0.0.1` makes iperf loop back on the host
without ever crossing the radio, reporting a bogus **~36 Gbps**. The server must bind
`10.0.0.1`.

**Pitfall 2 — the UPF container has no iperf3.** Run the *host's* iperf3 **inside the UPF
network namespace** (so it owns `tun0`/`10.0.0.1` but keeps the host mount namespace, hence
`/tmp` is the host's):
```bash
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
sudo nsenter -t $UPF_PID -n pkill -x iperf3                       # clear stale servers
sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -1 \
     --logfile /tmp/iperf_srv.log -D                              # one-shot, daemon, logged
# client (UE side):
iperf3 -c 10.0.0.1 -u -b 20M -t 20 -R     # -u UDP, -b rate, -R or plain per direction
```

**Pitfall 3 — the UDP *client* rate is not the radio rate.** Over UDP the client's
`bits_per_second` is the **send rate it pushed into the TUN**; the UE drops the excess at the
TUN when the radio can't keep up, so the client *over-reports* (this is where the fake
"20 Mbps" / "36 Mbps" readings came from). **The true UL rate is the server's *received*
rate**, taken from `/tmp/iperf_srv.log` (`grep bits/sec`). The sweep runs with
`IPERF_UDP=1 IPERF_UDP_RATE=20M` and parses the server log, not the client output.

**Pitfall 4 — UL-heavy TDD breaks *TCP* iperf entirely.** With `D M U U U` the DL is so
starved that TCP ACKs / the iperf control socket reset ("Connection reset by peer"), so UL
**must** be measured with UDP. (A more balanced 2 DL / 2 UL pattern keeps TCP alive if a TCP
number is needed.)

**Pitfall 5 — `end.sum` is empty under UDP-UL saturation.** When the UL is saturated the
iperf3 control socket dies before the summary is emitted, so `--get-server-output` /
`end.sum.bits_per_second` come back blank. The harness instead parses the **per-interval**
rows: throughput = mean of the interval rates, jitter = mean interval jitter, loss = Σ lost
/ Σ packets. Server-side loss stays ~0 % until the cliff (HARQ hides it); jitter and the MAC
retx counter are the sensitive UL-quality signals.

**Cross-check (ground truth).** Independently of iperf, the UE MAC `UL harq: X/Y` counter
(X = successful UL TBs) × TBS (~1.5 KB/TB at 17 RB / 64-QAM) gives the same ~5 Mbps, which
is how the iperf number was validated.

**Operational note.** The sweep self-manages a **single** iperf3 server
(`ensure_iperf_server` kills duplicates and starts one); two servers or two concurrent
sweeps collide with "the server is busy running a test" → 0 Mbps. **Never run two sweeps at
once** — they also share the configs, vrtsim, and CPU cores.

---

## 4. Why the UL is limited to ~5 Mbps / 10 MHz bandwidth

This is the standing limit. Three layered reasons — config, then PHY, then realtime.

### 4.1 The arithmetic of the ceiling (config)

- The cell is **24 PRB = 10 MHz** by construction (µ1, fs 15.36 Msps).
- **MCS is already maxed at 28** — no headroom there.
- `ul_prbblacklist = "0,1,2,3,20,21,22,23"` **hides 8 of 24 PRBs** → only **16 usable** →
  ~5 Mbps at 64-QAM. (The blacklist exists because the edge PRBs were where the BFP
  truncation / band-edge artifacts landed — §2.2.)

So at 10 MHz the throughput is fundamentally bounded: 16 PRB × MCS28 × the UL-heavy TDD
duty cycle ≈ 5 Mbps. To go higher you must **widen the bandwidth** (106 PRB = 40 MHz, or
273 PRB = 100 MHz). That is where the wall is.

### 4.2 Why wider bandwidth does **not** work on this tree (PHY)

Three independent failures block wide-BW, in increasing order of bandwidth:

**(a) SSB / PRACH frequency placement — fixed in config.** The naive `BW_PRB` change moved
the carrier center up and de-centered the fixed SSB → the UE couldn't find the SSB. Fixed
in the sweep's `build_chanmod`: keep `carrier_tx/rx`, UE-C, and SSB fixed at 4049.76 MHz;
move **pointA down** (`dl_absoluteFrequencyPointA = 669984 − (BW_PRB/2)*24`) and set the UE
`--ssb = (BW_PRB/2 − 10)*12`. At 106 PRB the UE then **syncs and finds CORESET0/SIB1
grant.**

**(b) SIB1 PDSCH decode fails outside 24 PRB — PHY tuning, the real blocker.** After the
frequency fix, 106 PRB still **NACKs SIB1** (`Got NACK on NR-BCCH-DL-SCH-Message (SIB1)`).
Root cause: the lab's **FH-tuned PHY** (commit `3b10464162`, the amplitude/timing
"PHY fix" baked in for the 7.2 freq-domain split where the *RU* does the IFFT) breaks
generic DL decode away from the 24-PRB operating point. This is the **same root cause** as
the rfsim DL-SIB1 failure (§5): the LDPC decoder produces *confident-but-wrong* LLRs
(`l_max=127` saturated, 8/8 iterations, wrong codeword) → the UE is demodulating real energy
from the **wrong resource elements** = a DL resource-mapping/TX-layout issue, not amplitude
(raising `tx_amp_backoff_dB` 12→36 did not fix it). So wide-BW throughput is blocked by PHY
tuning, **not** by the (now-correct) frequency config.

**(c) 100 MHz / 273 PRB — DU realtime crash.** 273 PRB drives the DU into a timeout/crash
(too heavy for realtime on this box) and leaks hugepages.

### 4.3 Why even the FH/air can't be pushed harder (realtime)

- **FH is massively over-provisioned, so FH latency is flat and load-independent.** Direct
  `dpdk-testpmd` VF↔VF measurement: **~3.18 Gbps per VF, ~6.36 Gbps aggregate, zero loss.**
  OAI loads the FH to only ~440 Mbps (≈7–14 %). The measured FH lead-time stayed flat at
  ~12 symbols (~428 µs margin) across iq8…iq16 (94→178 Mbps) and even at 442 Mbps — packet
  serialization (~1–9 µs) is negligible against the ~428 µs pipeline margin. **FH bandwidth
  is not the bottleneck; the per-slot timing *window* is.**
- **The realtime chanmod can't take 4–8× the sample rate.** `perform_channel_modelling`
  (`vrtsim.c:887`) is a **scalar, un-vectorized complex FIR** (literally
  `// TODO: Use AVX2 for this`). At 1×1 it is borderline; at 4×4 (≈16× cost) or wide-BW
  (4–8× sample rate) it overruns its core → "application layer too slow" → UE UL samples
  arrive late → gNB reads zero-filled buffers → `prach_I0 = 0.0 dB` → RA fails. A
  **core-pin fix** (pin the chanmod actors to isolated cores 24+/28+ instead of
  `init_actor(...,-1)`) unblocked 1×1 mobility and 2×2, but 4×4 / wide-BW still need the FIR
  **vectorized (AVX2/AVX512)**.
- **106 PRB realtime vrtsim+xran:** the gNB *does* run N_RB 106 and SIB1 decodes clean, but
  UL `prach_I0 = 0.0 dB` again (xran UL at 4× rate) → no attach. A genuine wide-BW UL FH
  issue, distinct from the SIB1 PHY bug.

**Bottom line on the 10 MHz limit:** the cell is 10 MHz because every path to wider BW is
blocked — config was fixable, but the **FH-tuned PHY breaks SIB1 decode outside 24 PRB**,
the **scalar chanmod can't sustain the higher sample rate in realtime**, and **100 MHz
crashes the DU**. Within 10 MHz the UL is further trimmed to ~5 Mbps by the 8-PRB blacklist
and the UL-heavy duty cycle.

---

## 5. The clean-tree / rfsim side-investigation (isolating PHY vs FH)

To separate PHY bugs from FH bugs, an rfsim (no-FH, monolithic gNB) path was tried.
**rfsim DL is broken on this tree** for the same reason as wide-BW SIB1: the FH-tuned PHY
(and a suspected `txdataF` fftshift/flat-buffer refactor `044ca835d6` in the monolithic
IFFT path) produces confident-but-wrong SIB1 LLRs. **vrtsim is immune** because the split
RU does the IFFT on a separate path — which is exactly why vrtsim attaches at 24 PRB and
rfsim does not. Decision: stand up a **clean OAI tree** (`git worktree` at release `2026.w22`,
commit `26efcc4989`, where rfsim DL is a hard CI gate) for the high-BW / non-realtime work,
keeping the FH-tuned tree for the FH measurements. The two halves are independent (rfsim
needs no xran; FH latency is injected synthetically from a NIC-measured load→latency LUT).

---

## 6. FH-latency experiment — what's measurable (current frontier)

The original goal was *FH latency → UL degradation*. Key findings:

- **UL channel estimation is in-slot** (PUSCH DMRS), so UL data demod does **not** suffer
  classic CSI aging from FH latency. FH latency hits UL only via (1) **timing loss** (late
  symbols dropped → retx — exactly the §2.1 bug) and (2) **stale link adaptation**.
- **VF rate-cap is a cliff, not a dial.** Fronthaul is CBR; any cap below the IQ load →
  unbounded queue → mbuf exhaustion → crash. Even a big pool (32×) just grows the queue to
  ~74 ms (bursty per-slot spikes) before draining → still misses the deadline. No stable
  graceful middle.
- **`T2a_min_up` is the one working graceful FH-latency injector** — but it gates the
  **DL** U-plane (`process_ru_uplane` = O-RU *receiving DL*). Raising it drops late DL
  packets (clean metric: `up_late` = RU "Packets late: N"). Demonstrated monotonic
  degradation: T2a_min 200→`up_late 0`, 400→~120, 450→~130 000 (UL→2.5 Mbps via broken DL).
- **`Ta3` / `Ta4` (UL FH windows) are no-ops here** — zero-latency VF↔VF loopback gives huge
  UL margin, so the acceptance gates never bite. They'd matter on a real FH link.
- The clean way forward is a **synthetic fixed per-packet delay** injected in the xran TX
  path (the UL analogue of the DL `T2a_min` late-bound), fed from the testpmd load→latency
  LUT.

Instrumentation added to every run (CSV): `fh_lead_mean/min` (DL FH margin in symbols),
`fh_late_total` (DL late drops), `ul_sym_present_pct` (UL symbol completeness, baseline
100 %), `ul_jitter_ms` / `ul_loss_pct`, and a **time-domain UL RX-SNR AGC**
(`--vrtsim.rx-target-snr-db`, validated: target 20→8 dB hits exactly; UL tracks SNR
20 dB→5.0 Mbps, 8 dB→2.1 Mbps).

---

## 7. Experiments & Results (measured data)

All numbers below are taken from the actual sweep logs under
`logs/iq_width_sweep/<timestamp>/summary.csv`. UL is the **server-side** received rate
(iperf3 in the UPF netns), not the client send rate. The cell is **24 PRB µ1 = 10 MHz**
throughout (`tx_bw_prb=24`, `numerology=1`, `carrier_hz=4 049 760 000`, band n77). I'm
reporting the trends honestly — including the ones that are flat, noisy, or cliff-shaped,
because most of the "tradeoff" axes turned out not to bend the way the hypothesis wanted on
this over-provisioned single-host loopback.

### 7.1 — Result 0: the 10 MHz link works end-to-end ✅

The baseline is solid and repeatable. All UL figures are server-side iperf3 over UDP with a
20 Mbit/s offered rate (`IPERF_UDP=1 IPERF_UDP_RATE=20M`, see §3.3); the ~5 Mbps figure is
the *received* rate at the UPF, i.e. the radio-limited goodput, well below the 20 Mbit/s
offered. Representative clean 1×1 ideal-channel runs:

| Run | iq | BW | nb | RX SNR dB | FH rx / tx / total Mbps | UL Mbps | UL jitter ms | UL loss | FH lead (sym) | UL sym present |
|---|---|---|---|---|---|---|---|---|---|---|
| `rxsnr_track_20dB_160100` | 9 | 24 PRB / 10 MHz | 1×1 | 20.0 | 104.9 / 45.8 / 150.8 | **4.995** | 1.83 | 0.00 % | 12.01 | 100.0 % |
| `20260531_120552` | 9 | 10 MHz | 1×1 | 42.7 | — | **5.004** | — | — | — | — |
| `20260531_124630` | 16 | 10 MHz | 1×1 | 45.7 | 177.6 / — / 254.0 | **5.006** | — | — | — | — |

So: UE syncs, attaches, gets an IP, passes NAS, and carries **~5 Mbps UL at 0 % loss,
~1.8 ms jitter, with 100 % UL symbol completeness**. Both iq9 (BFP) and iq16 (uncompressed)
work. This is the validation that the 10 MHz cell is functional — the thing all the §1–§3
bug-fixing was for.

**Honest caveat — attach flakiness ≈ 50 %.** Across the ~250 logged runs, roughly half come
up `ue-timeout` (UE never syncs or syncs-but-RA-fails, `prach_I0 = 0.0 dB`) — a per-bringup
timing-alignment transient, not a steady-state failure. The numbers above are the
*successful* bringups; the experiment harness uses retry-to-attach to get clean points. This
flakiness is real and is reported as-is.

### 7.2 — Compression (iq_width) → FH load: linear, as predicted; UL flat ✅/⚠️

Clean single sweep `20260531_140241` (1×1, ideal channel, all four widths back-to-back):

| iq_width | FH rx Mbps | FH total Mbps | RX SNR dB | UL Mbps | FH lead (sym) | UL loss |
|---|---|---|---|---|---|---|
| 8  | 94.0  | 135.2 | 38.55 | 4.999 | 12.01 | 0.00 % |
| 9  | 104.9 | 150.8 | 38.55 | 4.999 | 12.00 | 0.00 % |
| 12 | 137.8 | 197.4 | 38.55 | 5.001 | 12.00 | 0.00 % |
| 16 | 180.4 | 256.8 | 38.55 | 5.001 | 12.00 | 0.00 % |

- **FH load scales linearly with iq_width** exactly as `(3·iq_width+1)·num_prb` predicts
  (iq8→iq16 nearly doubles the bytes). ✅ This is the clean, expected result.
- **UL throughput, RX SNR, and FH latency margin are all FLAT** across the whole range.
  ⚠️ This is the honest null result: at 10 MHz / 1×1 the FH is so over-provisioned
  (180 Mbps offered into a ~6.4 Gbps loopback, §4.3) that compression buys you nothing on
  UL — there is **no compression-vs-throughput tradeoff visible here** because FH never
  bottlenecks. The expected "heavy compression helps under FH pressure" curve only appears
  once you artificially shrink the FH pipe (§7.5) or push BW/antennas (§7.3) — and those
  hit other walls first.

### 7.3 — Antennas (MIMO) → FH load scales ×N; 10 MHz holds, wide-BW cliffs

FH load scales with antenna count as expected (iq9):

| Config | FH rx Mbps | Note |
|---|---|---|
| 1×1 | 104.9 | baseline |
| 2×2 | 209.9 | 2× (`20260530_221945`, UL 4.991, SNR 42.5) |
| 4×4 | 419.8 | 4× (`20260530_211642`) |

- **2×2 at 10 MHz works** with chanmod ON (mobility): `20260531_144956` → UL 4.978, SNR 46.3;
  `20260531_145140` → UL 4.984, SNR 43.7. Per-run noisy (`20260531_142504` same config →
  UL 2.67, SNR 32.8) — the variance is bringup SNR, not a config difference.
- **4×4 at 10 MHz can work** but is fragile: `exp_chanmod_4x4_10mhz_3kmh` → status ok,
  **UL 4.998**, FH 710/1016 Mbps. Earlier symmetric-4×4 attempts gave **UL = 0** because the
  *server-side DL* chanmod (16 convolutions/slot) overran its core ("application layer too
  slow") even pinned — the same scalar-FIR wall as §4.3.

**Wide-BW is a hard cliff** — every attempt to exceed 10 MHz failed:

| Run | Target | FH total Mbps | Status | Why |
|---|---|---|---|---|
| `val_106prb_1x1` | 40 MHz (106 PRB) | 1085 | ue-timeout | SIB1 NACK / `prach_I0=0` |
| `exp_20mhz_4x4` | 20 MHz 4×4 | 637 | ue-timeout | chanmod overrun |
| `exp_chanmod_4x4_20mhz` | 20 MHz 4×4 | 2107 | ue-timeout | chanmod overrun |
| `exp_50mhz_4x4` | 50 MHz 4×4 | 1645 | ue-timeout | sample-rate wall |
| `exp_25mhz_4x4` | 25 MHz 4×4 | — | **ru-timeout (crash)** | DU realtime |

This is the empirical backing for §4: **10 MHz is the ceiling**, and the failure mode above
10 MHz is the FH-tuned PHY (SIB1) + the scalar chanmod + DU realtime, not the FH bandwidth
(the FH happily carried 2.1 Gbps before the *endpoints* fell over).

### 7.4 — RX SNR → UL throughput: the one clean monotonic tradeoff ✅

Using the time-domain RX-SNR AGC knob (`--vrtsim.rx-target-snr-db`, UL only):

| Target SNR dB | Measured SNR dB | UL Mbps | UL jitter ms | Run |
|---|---|---|---|---|
| 20 | 20.00 | **4.995** | 1.83 | `rxsnr_track_20dB_160100` |
| 8  | 8.00  | **2.148** | 4.92 | `rxsnr_track_8dB_160232` |

The AGC hits its target exactly (20.00/8.00) and **UL throughput tracks SNR monotonically**
while jitter rises as SNR falls. The same shape shows up incidentally in the noisy
chanmod runs (SNR ≈10 dB → UL ≈1.0–1.7; SNR ≈22 dB → UL ≈2.2; SNR ≥38 dB → UL ≈5.0). This
is the cleanest physical tradeoff in the whole dataset.

### 7.5 — FH latency → UL: only injectable on the DL path; sharp knee, then cliff ⚠️

The FH on this loopback is too fast to create natural latency, so latency had to be
*injected*. Two methods, both honest about their limits:

**(a) `T2a_min_up` — the one graceful knob (gates the DL U-plane at the O-RU).** Clean
retry-to-attach sweep (2×2, 3 km/h, iq9; metric = `up_late` = RU "Packets late"):

| T2a_min_up (µs) | up_late (fh_late_total) | UL Mbps | Note |
|---|---|---|---|
| 200 | 0       | ~4.4 | baseline window |
| 300 | 0       | ~5.0 | clean |
| 350 | ~8      | ~4.7 | first drops appear (`20260601_004209`: late=8, UL 4.994) |
| 400 | ~120    | ~4.0 | knee |
| 450 | ~130 000 | ~2.5 | **cliff** (retx ≈ 26 %) |
| ≥600 | thousands | 0 (no-attach) | DL link breaks (`20260601_005323`: late=4000, ue-timeout) |

Monotonic degradation with a sharp knee at 400→450 (drops jump ~1000×). **Caveat: this is
the *downlink* FH path** (`process_ru_uplane` = O-RU receiving DL) — UL collapses
*indirectly* because the UE loses DL/DCI. Confirmed by capping DU egress (`20260531_141132`):
FH lead went 12.0 → **−8.29 sym** (DL arrives after deadline), late=561 759, UL=0.

**(b) `Ta3` / `Ta4` — the true UL FH windows — are NO-OPs here.** Swept Ta4_max
{440,420,410,405} and Ta3 {470,900,1100}: `ul_sym_present_pct` stayed **100 %** and UL flat
~5 Mbps everywhere. Zero-latency VF↔VF loopback gives the UL such large margin that the
acceptance gates never fire. Honest negative result — they would bite on a real FH link.

**(c) VF rate-cap — a cliff, not a dial.** Capping RU/DU egress below the IQ load →
mbuf exhaustion → crash (small pool) or ~74 ms queue latency → no-attach (32× pool). No
stable graceful middle on a CBR fronthaul. Reported in §6.

### 7.6 — Mobility → UL: barely moves (proxy, not real Doppler) ⚠️

Mobility is a **`forgetfact` proxy** (`max_Doppler` is unimplemented). At 3 km/h
forgetfact=0.0133. 2×2 TDL-D runs at this setting give UL 4.96–4.98 when SNR is high
(`20260531_144956/145140`). Higher speeds (60 km/h, forgetfact 0.266) still gave UL ≈4.99
(per the 2×2 60 km/h validation). **Honest finding: at high SNR with a grant-capped
~5 Mbps UL, mobility barely changes throughput** — there's no CSI aging on UL (in-slot DMRS,
§6) and the channel variation doesn't reach the demod. 120 km/h (forgetfact 0.53) *does*
break things, but via **DL initial-sync failure** (SSB decorrelates faster than acquisition),
not UL degradation. So "mobility → UL throughput" is a weak/absent effect on this testbed,
and that is reported as such rather than dressed up.

### 7.7 — Summary of what each axis actually does

| Axis | Knob | Effect on UL @ 10 MHz | Honest verdict |
|---|---|---|---|
| **Link works** | — | 5 Mbps, 0 % loss, 100 % syms | ✅ validated, ~50 % attach flakiness |
| **Compression** | iq_width 8→16 | flat (FH load 94→180 Mbps, UL unchanged) | ⚠️ no tradeoff visible — FH over-provisioned |
| **Antennas** | 1×1→2×2→4×4 | FH ×N; UL stays ~5; 4×4 fragile | ✅ FH scales; ⚠️ chanmod overrun |
| **Bandwidth** | >24 PRB | — | ❌ cliff (SIB1/chanmod/DU crash) → 10 MHz ceiling |
| **RX SNR** | AGC 20→8 dB | 5.0 → 2.1 Mbps | ✅ clean monotonic tradeoff |
| **FH latency (DL)** | T2a_min 200→450 | 5.0 → 2.5 Mbps, then cliff | ⚠️ DL path; sharp knee |
| **FH latency (UL)** | Ta3 / Ta4 | none (present 100 %) | ⚠️ no-op on zero-latency loopback |
| **VF cap** | egress rate | crash / 74 ms | ❌ cliff, not a dial |
| **Mobility** | forgetfact (proxy) | ~flat at high SNR | ⚠️ weak; proxy not real Doppler |

The two axes that genuinely bend UL throughput on this testbed are **RX SNR** (clean) and
**injected DL FH latency via T2a_min** (sharp knee). Compression, antennas, and mobility
scale the *FH load* and the *channel* correctly but don't move UL goodput, because at 10 MHz
the UL is grant-capped at ~5 Mbps and the FH is ~6.4 Gbps over-provisioned — so neither the
FH pipe nor the channel is the binding constraint until you force them with an injected knob.

---

## Appendix A — Fix timeline (git)

**`openairinterface5g` (branch `compression-plus-timing-fix`):**

| Commit | What |
|---|---|
| `cd509aad8a` | oru-rebase-1 initial recopy working on single machine |
| `057d167ee`/`dae942c61` | BFP compression (no-comp path works; "extra bytes" in comp header) |
| `3b10464162` | **PHY fix** (ULSCH demod/decode amplitude+timing) — the FH-tuned PHY that later breaks wide-BW/rfsim SIB1 |
| `40eaf33c9c` | BFP compression without AVX512 |
| `565e936c19` | stability fix (spin-wait, `>>2` scale) |
| `47dcaef44b` | **iq16 PUSCH offset** — skip compression header for `compMeth=NONE` |
| `37b55fa535` | **FH UL fix** (reset tti+10) + chanmod core-pin + R-bucket + pthread-setname fixes |
| `a559a1f755` | vrtsim target-SNR AGC (real time-domain UL RX SNR) |

**`oran_lab` (branch `fh-latency-experiment`):** `0e9b835` sync success → `c10a7c0` phy fix
(UL throughput) → `6a6ad68` compression success → `840e405` stability → `55493cb` reliable
UDP UL capture → `fae7cc8` FH-latency experiment harness → `b10743c` RX-SNR AGC wiring.

## Appendix B — Build & run cheat-sheet

```bash
# FH code lives in a dlopen'd lib — rebuild THIS for any oaioran*.c / oran-*.c change:
cd .../openairinterface5g/build && ninja oran_fhlib_5g
# Other targets:
ninja nr-softmodem nr-oru nr-uesoftmodem vrtsim
# xran C-plane fixes (T1a/PRACH bugs A,B) live in libxran.so:
cd .../phy-f-1.0/fhi_lib/lib && TARGET=x86 RTE_SDK=$DPDK_INST make XRAN_LIB_SO=1 -j$(nproc)

# Between DPDK runs (DPDK doesn't clean on kill):
sudo rm -f /dev/hugepages/*map_*

# True UL rate (server-side, inside UPF netns):
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -1 --logfile /tmp/iperf_srv.log -D
```

## Appendix C — Key parameters

| Param | File | Value | Why |
|---|---|---|---|
| `T1a_cp_ul` | du_test.conf | `(285, 535)` | PRACH C-plane reaches RU before the slot (§1.2a) |
| `callbacks_per_slot` | oran-init.c | `14` | one RU wakeup per symbol |
| buffer reset offset | oaioran.c | `tti+10` | the zero-UL fix (§2.1) |
| `min_grant_prb` | du_test.conf | `16` | breaks the 5-RB inactive-UE cap (§3.1) |
| TDD pattern | du/ru_test.conf | `D M U U U` | UL-heavy (§3.2) |
| `ul_prbblacklist` | du_test.conf | `0,1,2,3,20,21,22,23` | hides 8 edge PRBs → 16 usable (§4.1) |
| `tx_amp_backoff_dB` | conf | `12` | correct for 7.2 freq-domain FH (RU does IFFT) |
| `IPERF_UDP` / `IPERF_UDP_RATE` | sweep env | `1` / `20M` | UDP UL, server-side measured (§3.3) |
