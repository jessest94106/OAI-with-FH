# IQ Width Sweep Report

Source CSV: `/home/jesse/oran_lab/logs/iq_width_sweep/dryrun_codex2/summary.csv`

| IQ width | compMeth | status | UE IP | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |
|---:|---:|---|---|---:|---:|---:|---:|---:|
| 9 | 1 | dry-run |  | 0.000 | 0.000 | 0.000 | 0.000 | 0 |
| 16 | 0 | dry-run |  | 0.000 | 0.000 | 0.000 | 0.000 | 0 |

## Notes

- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.
- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.
- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.
