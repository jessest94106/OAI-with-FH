# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260530_210248/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 8 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 36.949/10.900/38.800 | 135.187 | 135.224 | 4.995 | 0.000 | 52 |
| 9 | 1 | ue-timeout | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | n/a | 150.769 | 150.777 | 0.000 | 0.000 | 64 |
| 12 | 1 | ue-timeout | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | n/a | 197.426 | 197.438 | 0.000 | 0.000 | 60 |
| 16 | 0 | ue-timeout | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | n/a | 256.801 | 431.639 | 0.000 | 0.000 | 64 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1` (gNB+UE antenna count: `1`)
- Channel/device model: `vrtsim`
- Channel setup: **ideal passthrough (chanmod OFF)** — no TDL/delay-spread/mobility; RX SNR is set only by `iq_width` quantization + ploss. Enable with `CHANMOD=1`.
- Measured RX SNR (UL, gNB): iq8=36.949dB(min 10.900/max 38.800), iq9=dB(min /max ), iq12=dB(min /max ), iq16=dB(min /max )

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
