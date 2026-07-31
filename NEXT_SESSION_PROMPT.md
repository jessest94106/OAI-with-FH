# NEXT SESSION — START HERE

Read `/home/jesse/oran_lab/CATB_HANDOFF.md` **§17, §18, §19 first** (newest sections, at the
bottom). They contain the current state, what is measured vs assumed, and the exact next change.

---

## PASTE THIS AS THE OPENING PROMPT

> Read /home/jesse/oran_lab/CATB_HANDOFF.md §17-§19. We are finishing Cat-B Step 3 (RU UL
> combining). Current: end-to-end decodes but only ~3.1 Mbps vs the ~174 Mbps Cat-A baseline,
> because the RU only combines 5% of data symbols.
>
> Root cause is measured and recorded in §19: the UL C-plane is emitted ONE SECTION PER TDD
> PERIOD, whose header carries the period's FIRST UL slot, so the RU stores weights only at
> slots 1,6,11,16 while slots 2,3,4 are asked 9128 times and hit 0.
>
> Task 1: make `catb_bfw_get()` in radio/fhi_72/oaioran_ru.c resolve the lookup slot to the
> period's first UL slot, derived from `fh_cfg->frame_conf.nTddPeriod` (do NOT hardcode 5).
> Then run the standard verification and report coverage + throughput.
>
> Before any run, follow the RULES section of /home/jesse/oran_lab/NEXT_SESSION_PROMPT.md.

---

## STATE

| item | status |
|---|---|
| Cat-A baseline | **174.0 Mbps, MCS 28/28, attach 2/2** — unregressed, all knobs default OFF |
| 3a.1 DU emits BFW | DONE |
| 3a.2 RU registers | DONE (its "callback must fire" gate is impossible — xran discards the pointer) |
| 3a.3 RU combines | WORKS, but only 5% coverage |
| 3a.3 DU receives combined | WORKS (`h_eff = sum_a conj(w_a) H_a`) |
| **end-to-end** | **3.1 Mbps / MCS 7,0** vs ~174 target |
| Step 4 sweep | mechanism validated, blocked on Step 3 for a *real* (non-proxy) measurement |

Commits: `5eb1349` (§17), `ae783a8` (§18), `e28492d` (§19), plus code in the OAI tree.

---

## WORK QUEUE, IN ORDER

1. **Period-scoped weight lookup** (§19). Expect coverage 5% -> ~63%. Biggest single win.
2. **Per-symbol overwrite** (§18). Even on stored slots only 1580/2608 = 63% of asks hit: the PRB
   map is per (antenna, SLOT), so all 14 symbol-loop `catb_bfw_attach` calls overwrite one
   `bf_weight`. Needs multiple prbMap elements or ext-11 bundling (that is step 3b).
3. **Per-layer BFW.** `oaioran.c` hardcodes layer 0, so UE1 never gets a beam — this is why MCS is
   asymmetric (7,0). Needs per-layer weights on distinct eAxC.
4. **Then** measure the remaining gap. Wideband-vs-per-PRB costs a real but bounded amount
   (adjacent-PRB weight correlation measured 0.91-0.96 in Step 2), so do not expect exactly 174.

Known limitation, not yet a bug: the shm ring holds ONE global `dmrs_mask`, last-writer-wins.
Observed changing 0x0400 -> 0x0421. Fine for 2 symmetric UEs, wrong in general.

---

## RULES (each of these was learned by getting it wrong)

**MEASURE, DO NOT INFER.** Every diagnosis this project made by reading code was wrong (vintage,
RE stride, buffer placement, noise decorrelation, same-slot lookup — five, ~25 min each). Every
diagnosis made after logging an actual VALUE was right. Log magnitudes, never presence flags:
`n_ant=16` looked healthy for hours while the weight vector was all zeros.

The two artifacts that did the work, both reusable:
- exit-path census (`[CATB ATTACH] calls/off/nomap/dmrs_skip/read_fail/attached`)
- store/lookup slot histograms (`[CATB KEY store]`, `[CATB KEY lookup] hit/ask`)

**ONE long-running action per Bash call.** `bash run_multi_ue.sh ... &` chained inside an
already-backgrounded call orphans the run: the log dir is created and stays EMPTY. Cost ~25 min.

**Cleanup ordering before every run** — kill, WAIT, then purge, or DPDK panics in
`xran_ethdi_init_dpdk_io -> __rte_panic`. Cost ~25 min.
```bash
for p in $(pgrep -x nr-oru) $(pgrep -x nr-softmodem); do sudo kill -9 $p; done
sleep 4
sudo rm -rf /dev/hugepages/* /var/run/dpdk
sudo rm -f /dev/shm/catb_weights /dev/shm/vrtsim* /tmp/vrtsim_connection
sleep 3; awk '/HugePages_Free/' /proc/meminfo   # must read 8192
```

**Four-artifact mtime guard after ANY header change** (`common_lib.h`, `catb_weight_ring.h` are
shared). A stale `libvrtsim.so` caused three "crashes" that were one ABI mismatch:
```bash
ls -l --time-style=+%H:%M nr-softmodem nr-oru liboran_fhlib_5g.so libvrtsim.so
```

**Env allowlist trap.** Both run scripts pass an explicit `sudo -E ... env VAR=` list. An unlisted
variable is dropped SILENTLY and the feature does nothing while the run looks healthy. This nearly
invalidated a control run (`VRTSIM_UE_SPEED_KMH` was in no allowlist).

**Reject runs on the MCS signal, not throughput.** The intermittent single-UE fault (~1 in 3,
still undiagnosed) shows as one UE several MCS below the other. `run_catb_step4_sweep.sh` already
auto-rejects on `|mcs0-mcs1| > 4`, attach != 2/2, or 0 Mbps, and retries.

**Measurement rules.** 180 s minimum per throughput claim; average the LAST 60 s (an 8 s tail
spread +/-13%); CN preflight `docker logs --since 5m oai-amf | grep -c "no SMF candidate"`.

---

## VERIFICATION COMMAND

```bash
cd /home/jesse/oran_lab
OAI_XRAN_CAT=B OAI_CATB_WEIGHT_EXPORT=1 OAI_CATB_BFW=1 OAI_CATB_BFW_RX=1 \
VRTSIM_CATB_UL=1 OAI_CATB_UL_RX=1 \
OAI_UL_AVG_AGG=2 ADV=32768 BW=106 IQ_WIDTH=9 COMP_METH=1 \
N_UE=2 TS=0.02 CHANMOD=1 CHAN_TYPE=CDL_A CHAN_DS_US=0.1 NB_ANT_RX=16 \
VRTSIM_CDL_UE_AZ_DEG=0,90 OAI_UL_MU_COSCHED=1 OAI_UL_MU_PORTS=1 OAI_UL_MU_IRC=1 \
UESS_AGG=0,8,8,4,2 PER_UE_WAIT=700 IPERF_SECONDS=180 VRTSIM_RX_NOISE_SIGMA=7 \
bash run_multi_ue.sh
```
Read the result:
```bash
D=$(ls -td logs/multiue_* | head -1)
grep -a "CATB UL] ref="      "$D/ru.log" | tail -1   # coverage: combined vs no_weights
grep -a "CATB KEY lookup"    "$D/ru.log" | tail -1   # per-slot hit/ask
grep -a "CATB ATTACH"        "$D/du.log" | tail -1   # DU exit-path census
awk 'NR>1&&$2>0{t[n]=$1;b[n]=$2;m[n]=$4;n++}END{l=n-1;f=l;while(f>0&&t[l]-t[f]<60)f--;
  printf "SIM Mbps=%.1f MCS=%s\n",(b[l]-b[f])*8/(t[l]-t[f])/1e6*50,m[l]}' "$D/aggregate_goodput.csv"
```
**Gate for Step 3 complete: ~174 Mbps, MCS 28/28, attach 2/2.**
Always re-run the Cat-A control (all Cat-B knobs off) after any change to shared decode code.

---

## SCOPE REMINDER

The project deliverable is **Step 4**: a degradation surface (throughput vs weight-loop delay x UE
speed) plus a maximum tolerable loop latency. Step 3 is what makes that a statement about O-RAN
7.2 Cat-B rather than about channel aging in general — it pins the delay to the real timing budget
(`Ta3_up` 200us + T_proc + `T1a_cp_ul` 285us = 485us against a 500us slot => d = 1-2 forced),
delivers the 87.5% UL fronthaul reduction, and makes the §9 C-plane congestion prediction testable.

A Cat-A proxy sweep can produce the *curve* without Step 3, but `d` is then a free parameter with
no referent — which is why Step 3 is being finished first.
