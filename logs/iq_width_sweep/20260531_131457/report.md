# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/20260531_131457/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 16 | 0 | ok | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | 43.681/30.900/44.400 | 508.055 | 508.100 | 5.005 | 0.000 | 65 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1` (gNB+UE antenna count: `2`)
- Channel/device model: `vrtsim`
- Channel setup (chanmod ON):
    - Profile (TDL-A etc): `TDL_D`
    - Delay spread (ds_tdl): `0.3` us
    - Channel noise / path-loss: `-30` dB / `0` dB
    - UE mobility (forgetfact PROXY; max_Doppler NOT implemented): `0.26613`
    - vrtsim timescale: `1.0`
- Measured RX SNR (UL, gNB): iq16=43.681dB(min 30.900/max 44.400)

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
