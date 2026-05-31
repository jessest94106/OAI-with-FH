# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/stability_after_fix3_iq9_20260526_233601_3/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 9 | 1 | ue-timeout | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 67.766/53.600/74.300 | 151.908 | 151.916 | 0.000 | 0.000 | 133 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1`
- Channel/device model: `vrtsim`

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
