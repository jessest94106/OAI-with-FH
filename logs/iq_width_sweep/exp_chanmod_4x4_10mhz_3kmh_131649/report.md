# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/exp_chanmod_4x4_10mhz_3kmh_131649/summary.csv`

| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|
| 16 | 0 | ue-timeout | 1 | vrtsim | 4049760000 | 24/24 | 24/24 | 1 | 1/1 | n/a | 1016.107 | 1016.164 | 0.000 | 0.000 | 63 |

## Radio Context

- Carrier: `4049760000` Hz
- Bandwidth/RB: tx/rx `24/24` PRB, dl/ul `24/24` RB
- Numerology: `1`
- Antennas: tx/rx `1/1` (gNB+UE antenna count: `4`)
- Channel/device model: `vrtsim`
- Channel setup (chanmod ON):
    - Profile (TDL-A etc): `AWGN`
    - Delay spread (ds_tdl): `0` us
    - Channel noise / path-loss: `-30` dB / `0` dB
    - UE mobility (forgetfact PROXY; max_Doppler NOT implemented): `0.01331`
    - vrtsim timescale: `1.0`
- Measured RX SNR (UL, gNB): iq16=dB(min /max )

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.
