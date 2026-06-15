# OAI-with-FH — OAI 5G NR O-RAN 7.2 split over a **real**, **non-real-time** fronthaul

A single-host lab that runs the full OpenAirInterface 5G NR **O-RAN 7.2 split**
(gNB-DU + O-RU + UE + 5GC) over a **real DPDK/SR-IOV xran fronthaul**, with a patched
**non-real-time clock dilation** (`XRAN_TIMESCALE`) so the whole split can run
slower-than-real-time on commodity hardware while preserving simulated throughput
(`iperf = wall-clock ÷ timescale = sim rate`).

## Headline result

The full **BFP IQ-width range — 8 / 9 / 10 / 12 / 16 — runs at 273 PRB / 100 MHz.**
Every apparent "wall" above BFP-9 turned out to be OAI software tuned for real-time
hardware, **not** a hardware or O-RAN-protocol limit:

| IQ width | FH load (sim) | UL (sim) | status | what unblocked it |
|---|---|---|---|---|
| 8 | 1.45 Gbps | ~63 Mbps | ✅ | baseline |
| 9 | 1.62 Gbps | ~60 Mbps | ✅ | baseline |
| 10 | 1.80 Gbps | ~66 Mbps | ✅ | spin-cap (`OAI_FH_SPIN_CAP`) |
| 12 | 2.14 Gbps | ~68 Mbps | ✅ | O-RAN U-plane fragmentation |
| 16 | 2.75 Gbps | ~68 Mbps | ✅ | fragmentation (uncompressed) |

FH load is validated to **<0.5%** against first principles (`FH = N_PRB·B_w·active_sym/s·8 + headers`);
UL throughput is **air-capacity-limited and FH-IQ-width-independent** (flat while FH load nearly
doubles). Full investigation log, every root cause, and the FH/UL math:
**[`FH_LOAD_VS_UL_FINDINGS.md`](FH_LOAD_VS_UL_FINDINGS.md)**.

## Components — submodules point at the forks that carry the fixes

| submodule | path | fork & branch |
|---|---|---|
| **OAI** (DU / O-RU / UE) | `oaicicd/test_dir/openairinterface5g` | **[jessest94106/openairinterface5g @ `compression-plus-timing-fix`](https://github.com/jessest94106/openairinterface5g/tree/compression-plus-timing-fix)** |
| **xran / fhi_lib** (the O-RAN 7.2 FH library) | `oaicicd/test_dir/phy-f-1.0` | **[jessest94106/phy-f-1.0 @ `xran-timescale`](https://github.com/jessest94106/phy-f-1.0/tree/xran-timescale)** |

The actual code fixes live in those two forks:

- **[OAI fork](https://github.com/jessest94106/openairinterface5g/tree/compression-plus-timing-fix)** — q-jump (`OAI_FH_MAX_QUEUE_NO_JUMP`), spin-cap (`OAI_FH_SPIN_CAP`), iq≥12 MTU **U-plane fragmentation**, `numPrbc==0` ALL-PRB decode, and full-band UL TDA grants.
- **[xran / phy-f-1.0 fork](https://github.com/jessest94106/phy-f-1.0/tree/xran-timescale)** — `XRAN_TIMESCALE` non-real-time clock dilation and `XRAN_MAX_FRAGMENT 7→16` (which the fragmentation depends on).

## Architecture

- **DU** — `nr-softmodem` (OAI), real xran FH TX/RX over Intel X710 SR-IOV VFs.
- **O-RU** — `nr-oru` (custom OAI executable) ↔ UE over a vrtsim shared-memory time-domain IQ channel.
- **UE** — `nr-uesoftmodem`, vrtsim client.
- **5GC** — OAI 5G core in Docker (`oai-cn5g/`).
- **Fronthaul** — eCPRI U-plane over DPDK/SR-IOV; supports both a same-PF VEB path and a **2-physical-port DAC loopback** (`run_iq_2port.sh`).
- **Time** — non-real-time dilation via three clock anchors: `XRAN_TIME_EPOCH`, `XRAN_TIMESCALE`, and the vrtsim ring timescale.

## Quick start

```bash
# 1. fronthaul: hugepages, X710 VFs, MACs, DPDK bind
bash prepare_network.sh

# 2. 5G core
cd oai-cn5g && docker-compose up -d && cd ..

# 3. 273-PRB / 100 MHz IQ-width sweep on the 2-physical-port fabric
#    (BFP-10 default knobs baked into run_du.sh)
WIDTHS_SWEEP="8 9 10 12 16" bash run_iq_2port.sh
```

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/jessest94106/OAI-with-FH.git
```

## Tunable knobs (the non-real-time-dilation fixes)

| env var | default | what it controls |
|---|---|---|
| `OAI_FH_MAX_QUEUE_NO_JUMP` | 8 | DU slot-sync FIFO depth before jump-to-latest (absorbs bursty FH slip) |
| `OAI_FH_SPIN_CAP` | 2000 | consumer spin-wait cap for a late tail-symbol fragment (the iq10 "wall") |
| `XRAN_TIMESCALE` / `--vrtsim.timescale` | 0.25 | non-real-time dilation factor (sim_rate = wall_rate ÷ timescale) |

## Key documents

- **[`FH_LOAD_VS_UL_FINDINGS.md`](FH_LOAD_VS_UL_FINDINGS.md)** — canonical investigation log (rev 5–19): the Ta4 attach-lottery, the TTI-slip producer/consumer race, the iq10 spin-cascade root cause, the fragmentation fix, and the FH/UL first-principles validation.
- [`WIDEBW_4X4_SWEEP_PLAN.md`](WIDEBW_4X4_SWEEP_PLAN.md) — wide-BW × antenna UL sweep plan.
- [`RFSIM_UL_THROUGHPUT_HANDOFF.md`](RFSIM_UL_THROUGHPUT_HANDOFF.md) — the clean rfsim (no-FH) tree for UL-throughput work.
- [`ORU-REBASE-1_PLUS_COMPRESSION_BUILD_INSTRUCTIONS_x86_FINAL.md`](ORU-REBASE-1_PLUS_COMPRESSION_BUILD_INSTRUCTIONS_x86_FINAL.md) — xran + OAI build instructions (x86).
- [`OAI_DEBUGGING_TECHNICAL_REPORT.md`](OAI_DEBUGGING_TECHNICAL_REPORT.md) — technical report.

---
_Co-developed with Claude Code._
