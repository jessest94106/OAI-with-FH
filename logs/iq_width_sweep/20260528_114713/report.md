# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260528_114713/summary.csv`

| IQ width | compMeth | status | UE # | FH UL/DL/Total Mbps | User iperf3 UL/DL Mbps |
|---:|---:|---|---:|---:|---:|
| 9 | 1 | ok | 1 | 45.427/108.900/154.327 | 0.000/0.000 |
| 16 | 0 | ue-timeout | 1 | 72.959/182.321/255.280 | 0.000/0.000 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1`
- Channel model: TDL-A (model id 0)
- Delay spread: 10.0 ns
- Mobility: 1.5 m/s
- VRTSIM path loss: n/a dB (`n/a` for CIRDB/taps unless gain is embedded in taps)
- VRTSIM noise power: n/a sample value (`0` means no configured global noise in current logs)

| IQ width | DU post-combining SNR avg/min/max dB | FH max Mbps | FH samples | trial dir |
|---:|---|---:|---:|---|
| 9 | 29.098/0.000/39.000 | 154.342 | 161 | `/home/jesse/oran_lab/logs/iq_width_sweep/20260528_114713/iq9` |
| 16 | n/a | 255.290 | 60 | `/home/jesse/oran_lab/logs/iq_width_sweep/20260528_114713/iq16` |

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH UL/DL/Total is reported as parsed rx/tx/total average Mbps after dropping the first warmup samples.
- DU SNR is the post-combining PHY estimate parsed from `ULSCH ... trace` lines; it is not a configured vrtsim input/channel SNR.
