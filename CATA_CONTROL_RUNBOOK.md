# Cat-A control run — runbook

Purpose: prove the **Cat-A baseline is unregressed** by the Cat-B work, and use it as the
**rig health check** whenever runs start behaving oddly.

Expected result: **~174 Mbps (sim), MCS 28/28, attach 2/2.**
Last two measurements on this tree: **175.2** and **174.3 Mbps**.

---

## 0. Tree state this was validated on

| repo | path | branch | commit |
|---|---|---|---|
| oran_lab | `/home/jesse/oran_lab` | `catb-srs-ru-mmse` | `b35934d` |
| openairinterface5g | `oaicicd/test_dir/openairinterface5g` | `catb-instrumentation` | `8f90259139` |
| phy-f-1.0 (xran) | `oaicicd/test_dir/phy-f-1.0` | `xran-timescale` | `ba5dfd8` (pristine) |

**DO NOT SWITCH BRANCHES TO RUN CAT-A.** Cat-A vs Cat-B is chosen by ENV VARS at runtime, not by
branch — every Cat-B knob defaults OFF, so omitting them gives the Cat-A path from the same
binaries. Switching branches DEFEATS the test: the whole point is to prove the shared decode-path
edits in `nr_ulsch_demodulation.c` (accumulate-then-shift, regulariser floor, conjugation) did not
regress the baseline. On another branch those edits are absent and a regression passes unnoticed.

No rebuild needed. Binaries live in `oaicicd/test_dir/openairinterface5g/build/`.

---

## 1. Reset — ONLY if runs have been failing, or the rig sat idle for hours

Skip if the last run was healthy: `run_multi_ue.sh` already pkills, purges `/dev/hugepages`, and
cycles `nr_hugepages` itself.

```bash
docker restart oai-smf oai-upf oai-amf && sleep 40
docker ps --format '{{.Names}} {{.Status}}' | grep -E "smf|upf|amf"   # all (healthy)

HP=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
echo 0 | sudo tee $HP >/dev/null; sleep 2
sudo find /dev/hugepages -type f -delete; sudo rm -rf /var/run/dpdk
sudo rm -f /dev/shm/catb_weights /dev/shm/vrtsim* /tmp/vrtsim_connection
echo 8192 | sudo tee $HP >/dev/null; sleep 3
awk '/HugePages_Free/' /proc/meminfo        # GATE: must read 8192
```

`find -type f -delete` alone CANNOT reclaim mapped hugetlbfs entries — the `nr_hugepages`
0-then-8192 cycle is what actually frees them.

---

## 2. Launch — in its OWN command, with NO OAI binary names in the command line

```bash
cd /home/jesse/oran_lab
OAI_XRAN_CAT=B OAI_UL_AVG_AGG=2 ADV=32768 BW=106 IQ_WIDTH=9 COMP_METH=1 \
N_UE=2 TS=0.02 CHANMOD=1 CHAN_TYPE=CDL_A CHAN_DS_US=0.1 NB_ANT_RX=16 \
VRTSIM_CDL_UE_AZ_DEG=0,90 OAI_UL_MU_COSCHED=1 OAI_UL_MU_PORTS=1 OAI_UL_MU_IRC=1 \
UESS_AGG=0,8,8,4,2 PER_UE_WAIT=700 IPERF_SECONDS=180 VRTSIM_RX_NOISE_SIGMA=7 \
bash run_multi_ue.sh
```

Takes ~8 min. Cat-A **is** this command: it is the Cat-B line minus `OAI_CATB_*` and
`VRTSIM_CATB_UL`. Keep `OAI_XRAN_CAT=B` — that selects the xran category both ends agree on, NOT
the Cat-B feature set.

---

## 3. Read

```bash
D=$(ls -td logs/multiue_* | head -1); echo "$D"
grep -ac "Interface oaitun_ue1 successfully configured" "$D"/ue*.log   # want 1 and 1
awk 'NR>1&&$2>0{t[n]=$1;b[n]=$2;m[n]=$4;n++}END{l=n-1;f=l;while(f>0&&t[l]-t[f]<60)f--;
  printf "SIM Mbps=%.1f MCS=%s\n",(b[l]-b[f])*8/(t[l]-t[f])/1e6*50,m[l]}' "$D/aggregate_goodput.csv"
awk 'NR<=2||NR%15==0' "$D/aggregate_goodput.csv" | head -6
```

**PASS:** attach 2/2, ~174 Mbps, MCS 28/28, with MCS climbing `0 -> 11,6 -> 23,18 -> 28,28`.
A flat MCS or a frozen `sum_lcid4` is a FAIL even if the final number looks close.

---

## 4. Traps — each of these cost real runs

**`pkill -f` self-match — the expensive one.**
`run_multi_ue.sh`'s preflight runs `sudo pkill -9 -f nr-softmodem`. `-f` matches the ENTIRE command
line, so any shell whose argv merely MENTIONS the binary is killed — including the one launching
the script. Symptom: the log dir is created and stays EMPTY, exit 1, no stderr.
**Never put `nr-softmodem` / `nr-oru` / `nr-uesoftmodem` / `ul_saturate.py` in the same command
line that invokes the harness.** Keep cleanup in a SEPARATE call. Cost ~6 runs, all misread as
rig flakiness.

**`pgrep -c -f "..."` counts your own shell.** It returns 1 with no orphan present. Filter your own
command line out before believing any `-f` count.

**`timeout` + `tail` hides output.** `tail` buffers to EOF and is killed with the pipeline, so a
healthy run looks like an instant silent death. Redirect to a FILE and read it afterwards.

**Cat-A IS the rig check.** Run it the moment behaviour gets odd — do not wait. The documented CN
preflight `docker logs oai-amf | grep -c "no SMF candidate"` reads 0 THROUGHOUT the stale-context
failure mode, and PRACH sits at ~20 dB for both the runs that attach and those that do not, so
NEITHER documented preflight detects it. Cat-A failing to attach is the only reliable signal.
CN staleness tracks ELAPSED TIME, not just run count (it recurred after a ~15 h idle gap).

**One run is not a result.** N>=3 before believing anything. This project has a ~1-in-3
intermittent single-UE fault, and one run this session looked like a breakthrough and was
contradicted by three repeats.
