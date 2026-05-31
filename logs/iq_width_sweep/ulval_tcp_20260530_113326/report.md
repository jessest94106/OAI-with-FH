# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/ulval_tcp_20260530_113326/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 8 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 38.550/31.000/38.800 | 135.217 | 135.222 | 4.643 | 0.000 | 27 |
| 9 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 38.550/31.000/38.800 | 150.769 | 150.777 | 4.608 | 0.000 | 26 |
| 10 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 38.550/31.000/38.800 | 166.321 | 166.330 | 4.634 | 0.000 | 26 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1` (gNB+UE antenna count: `1`)
- Channel/device model: `vrtsim`
- Channel setup: **ideal passthrough (chanmod OFF)** — no TDL/delay-spread/mobility; RX SNR is set only by `iq_width` quantization + ploss. Enable with `CHANMOD=1`.
- Measured RX SNR (UL, gNB): iq8=38.550dB(min 31.000/max 38.800), iq9=38.550dB(min 31.000/max 38.800), iq10=38.550dB(min 31.000/max 38.800)

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
