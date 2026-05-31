# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260530_215317/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 9 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 30.394/30.200/30.400 | 150.769 | 150.777 | 4.989 | 0.000 | 52 |
| 16 | 0 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 38.750/31.200/39.000 | 254.026 | 254.045 | 4.990 | 0.000 | 52 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1` (gNB+UE antenna count: `1`)
- Channel/device model: `vrtsim`
- Channel setup (chanmod ON):
    - Profile (TDL-A etc): `TDL_D`
    - Delay spread (ds_tdl): `0.3` us
    - Channel noise / path-loss: `-30` dB / `0` dB
    - UE mobility (forgetfact PROXY; max_Doppler NOT implemented): `0.26613`
    - vrtsim timescale: `1.0`
- Measured RX SNR (UL, gNB): iq9=30.394dB(min 30.200/max 30.400), iq16=38.750dB(min 31.200/max 39.000)

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
