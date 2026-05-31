# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260530_211053/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 9 | 1 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 31.577/31.400/31.700 | 150.769 | 150.777 | 3.088 | 0.000 | 52 |

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
    - UE mobility (forgetfact PROXY; max_Doppler NOT implemented): `0.53225`
    - vrtsim timescale: `1.0`
- Measured RX SNR (UL, gNB): iq9=31.577dB(min 31.400/max 31.700)

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
