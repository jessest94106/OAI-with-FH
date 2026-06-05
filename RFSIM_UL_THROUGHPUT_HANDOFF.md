# Handoff: Maximize UE UL Throughput on the clean rfsim tree

Carry-over from the FH-tree (vrtsim + O-RAN 7.2 xran) UL investigation. Goal on the rfsim
side: push a UE's uplink throughput as high as possible. This note says what we learned, why
the FH tree capped at ~7 Mbps, what transfers, and the concrete levers to pull on rfsim.

---

## 1. What the FH tree taught us (the ceiling and its cause)

- **Single-UE UL capped at ~7 Mbps** on the realtime FH tree. Per-slot the link was already
  optimal: **24 PRB, MCS 28 / 64-QAM, 0 % BLER, 0 retx**. The cap was purely **grant cadence**:
  the gNB granted **exactly 1 UL slot per TDD period** (measured 400 TBs/s = 400 periods/s).
- **Root cause:** OAI's scheduler keeps **one outstanding UL grant per UE** (`pf_ul()` won't
  give a UE a 2nd grant until the 1st is transmitted/decoded). The grant turns over once every
  ~k2 slots. With **k2 = 6** (`min_rxtxtime = 6`), that's ~1 grant per 5-slot period.
- **Why k2 couldn't be lowered on the FH tree:** `min_rxtxtime = 6` is needed for the realtime
  software-FH pipeline. Tested: k2 = 4 → no change; **k2 = 2 → UE crashes**
  (`feedback_ti >= GET_DURATION_RX_TO_TX`, nr_ue_procedures.c:1032).
- **Disproven levers (all left it at 7):** BSR `periodicBSR sf5→sf1`; `min_rxtxtime` 6→4;
  PUSCH TDA-list expansion. Each is documented in project memory.
- **Validated win on the FH tree: 5.0 → 7.06 Mbps (+41 %)** by removing `ul_prbblacklist`
  (freed 8 edge PRB → 24 usable) **and** `min_grant_prb = 24`.
- **Multi-UE (Path B) on the FH tree:** harness works (UEs attach in separate netns), but
  (a) ideal channel → per-UE MCS collapses to QPSK (no aggregate gain), and (b) chanmod (to
  control SNR) needs **per-UE channel models / a CIRDB** that aren't wired (`channel_desc is
  NULL per UE` crash; CIRDB has no data on disk). So 21 Mbps was blocked at multiple layers.

## 2. Why rfsim can go higher

The FH tree is a single-UE, realtime, ideal-channel demonstrator. rfsim is **not bound by the
realtime FH timing wall**, which unlocks the two things the FH tree couldn't do:

1. **Small k2.** Lower `min_rxtxtime` (toward the UE's spec floor, ~2–3 for µ1) so the
   one-outstanding-grant **cycles faster → a single UE fills multiple UL slots per period →
   multiplied single-UE UL.** (On rfsim the UE isn't wall-clock-bound; only the spec/capability
   floor applies, so test how low it goes before the `feedback_ti` assert.)
2. **Wide bandwidth cleanly.** The FH-tuned PHY breaks SIB1 decode above 24 PRB; the clean
   rfsim tree (CI-gated) attaches at 106 PRB (40 MHz) and beyond.

## 3. Levers to maximize UL on rfsim (apply together)

| Lever | What / how | Note |
|---|---|---|
| **min_rxtxtime ↓** | `--gNBs.[0].min_rxtxtime 2` (or 3) | **THE key lever** — more grants/period for one UE. Find the floor before `feedback_ti` assert. |
| **ul_prbblacklist** | set `""` | free all PRB (safe; was an FH-only compression workaround) |
| **min_grant_prb** | = full band (e.g. 106/273) | full-band grant floor |
| **Bandwidth** | 106 PRB (40 MHz) / 273 (100 MHz) | `gnb_clean_106.conf` exists; clean tree handles wide BW |
| **256-QAM UL** | `pusch_Config mcs_Table = qam256` | +~33 % over 64-QAM **if RX SNR ≳ 25 dB** + UE cap |
| **TDD ratio** | UL-heavy `D M U U U` if UL-focused | more UL slots/period |
| **PUSCH TDA** | if `min_rxtxtime ≥ N_ul`, apply the TDA fix | else (small k2) native code adds the TDAs. See §5. |
| **Multiple UEs** | optional, for aggregate beyond single-UE | reusable harness exists, see §4 |

## 4. Reusable assets (already built this session)

- **CN: 3 subscribers provisioned** — IMSI `2089900007487 / …7488 / …7489`, all same
  key `fec86ba6…`, opc `C42449363…` (cloned via `mysql -uroot -plinux` `INSERT … SELECT`).
  SMF uses `local_subscription_infos` keyed by (slice, DNN) — **not per-IMSI** — so no per-UE
  session config needed; any sst=1 / DNN "oai" UE gets a PDU session.
- **Multi-UE launch pattern (vrtsim, adapt for rfsim):** each UE in its own **network
  namespace** (TUN `oaitun_ue1` per netns; `/dev/shm` shared). `run_ue.sh` made netns-aware
  (`UE_NETNS` → `ip netns exec`, `UE_CORES` env). Orchestrators `/tmp/multi_ue.sh`,
  `/tmp/multi_ue_cm.sh`. For **rfsim**, multi-UE differs (rfsimulator `serveraddr`/port per
  client, or `--num-ues`) — re-derive; the netns + CN-subscriber parts transfer directly.

## 5. The TDA fix (FH-tree source change — port only if needed)

On the FH tree I edited `openair2/LAYER2/NR_MAC_gNB/nr_radio_config.c` `nr_rrc_config_ul_tda()`:
when `N_ul <= k2` (large k2 vs few UL slots), the default builds a TDA for only **one** full UL
slot, so the preprocessor can reach only 1 UL slot/period. Added an `else` branch that adds
full-UL TDAs for `k2+1 … k2+N_ul` so **all** UL slots are reachable. **On rfsim with small
`min_rxtxtime` (k2 < N_ul), the existing `N_ul > k2` branch already does this** — so the fix is
only needed if you keep a large k2. (The clean rfsim tree is a *separate* checkout, so this
source edit would have to be re-applied there if wanted.)

## 6. Measure it right (don't repeat the traps)

- **UL = server-side iperf3 received rate**, run inside the UPF netns
  (`nsenter -t $(docker inspect -f '{{.State.Pid}}' oai-upf) -n iperf3 -s -B 10.0.0.1 …`).
  The UE/client UDP rate over-reports (UE drops excess at the TUN).
- **Report RX (time-domain) SNR, not ULSCH/post-FFT SNR** (the latter is inflated ~+17 dB by
  OFDM processing gain). Use the vrtsim AGC (`--vrtsim.rx-target-snr-db`) or rfsim channel SNR.
- Sanity-check with the gNB `build/…/nrMAC_stats.log`: `ulsch_rounds`, MCS, Qm, BLER, NPRB.
- Confirm **0 % loss** and a **sustained** rate (not a lossy burst).

## 7. Gotchas

- **SMF hangs after ~30–48 h** of CN uptime → PDU-session establishment stalls. Fix: full CN
  restart `cd ~/oran_lab/oai-cn5g && docker-compose down && docker-compose up -d` (v1, hyphenated).
- **NRF SBI is HTTP/2** — a plain `curl …/nf-instances?nf-type=SMF` returns empty even when the
  SMF is registered (false negative). Verify via `docker logs oai-nrf | grep "NF type SMF.*REGISTER"`.
  CN static IPs: nrf .130, amf .132, smf .133, upf .134.
- **Attach is timing-flaky** (~50 % per cold start single-UE; worse for N UEs) → use
  retry-to-attach loops.
- **Clean rfsim tree:** `oai_rfsim_clean/` (git worktree, release `2026.w22`, commit
  `26efcc4989`); binaries in `cmake_targets/ran_build/build/` (NOT `build/`). Launcher
  `run_rfsim_clean.sh`, `gnb_clean_106.conf` (106 PRB / 40 MHz, band 78, UE carrier 3319680000).
- **Earlier rfsim "126 Mbps @ 40 MHz" was NOT a clean number** — it had AWGN + 21 % UDP loss
  (200 Mbit/s offered, 126 received). Re-measure at 0 % sustained before quoting.

## 8. Target

Highest single-UE UL on rfsim = **wide BW (106/273 PRB) × low `min_rxtxtime` (more UL slots/period)
× max MCS (256-QAM at high RX SNR) × all UL slots reachable**, measured server-side at 0 % loss.
If single-UE saturates, add UEs (netns + the 3 provisioned subscribers) for aggregate.
