# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260527_154413/summary.csv`

| IQ width | compMeth | status | UE # | FH UL/DL/Total Mbps | User iperf3 UL/DL Mbps |
|---:|---:|---|---:|---:|---:|
| 9 | 1 | ok | 1 | 45.427/108.900/154.327 | 0.000/0.367 |
| 16 | 0 | ue-timeout | 1 | 72.960/182.321/255.281 | 0.000/0.000 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1`
- Channel model: TDL-A (model id 0)
- Delay spread: 10.0 ns
- Mobility: 1.5 m/s

| IQ width | SNR avg/min/max dB | FH max Mbps | FH samples | trial dir |
|---:|---|---:|---:|---|
| 9 | 33.461/0.000/39.000 | 154.345 | 108 | `/home/jesse/oran_lab/logs/iq_width_sweep/20260527_154413/iq9` |
| 16 | n/a | 255.295 | 64 | `/home/jesse/oran_lab/logs/iq_width_sweep/20260527_154413/iq16` |

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH UL/DL/Total is reported as parsed rx/tx/total average Mbps after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
