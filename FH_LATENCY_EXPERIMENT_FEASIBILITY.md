# FH-latency → UL-throughput experiment: feasibility / architecture review

**Hypothesis under test:** UE mobility / delay spread make the channel time-varying;
fronthaul (FH) latency delays the channel info so it is *aged* by the time the DU
uses it, degrading UL throughput. Compression (smaller `iq_width`) shrinks the FH
payload → lower FH latency → less aging, but too-aggressive compression adds
quantization error. Net: an optimal `iq_width` exists, and it shifts with
mobility / FH load.

This document records what the testbed **can** and **cannot** do for this, with code evidence.

---

## TL;DR feasibility

| Experiment knob | Feasible? | How / caveat |
|---|---|---|
| Single UE | ✅ yes | current default |
| Sweep quantization (`iq_width` 8/9/10/12/14/16) | ✅ yes | already the sweep's main axis; FH payload = `(3·iq_width+1)·num_prb` bytes/sym/ant |
| Channel: TDL-A/B/C/D/E + delay spread | ✅ yes | `vrtsim.chanmod 1` + a `channelmod` section (`type=TDL_A`, `ds_tdl=<µs>`). Currently OFF (ideal channel). |
| RX SNR / noise | ✅ yes | `noise_power_dB` (and `ploss_dB`) in the channel model |
| Increase antennas (MIMO, ↑ FH load) | ✅ single-UE up to 4×4 | `MAX_NUM_ANTENNAS=4` (oaioran_ru.c:63); set `nb_tx/nb_rx`+`pusch_AntennaPorts`+`maxMIMO_layers`. FH load scales ×antennas. |
| Increase single-UE throughput demand | ✅ yes | UDP flood / more RBs / `min_grant_prb` |
| Increase **UE count** (↑ FH load) | ⚠️ partial | vrtsim supports up to 16 (`vrtsim.num_ues`, per-UE `vrtsim.ue_id`), but needs: N separate UE processes, N CN subscribers, and **chanmod ON** for multi-antenna. run_ue.sh launches only 1 → harness work needed. |
| Measure FH latency | ✅ yes | vrtsim "TX budget" histogram (µs of slack before peer reads); xran one-way-delay (xran_delay_measurement.c) |
| **Inject** FH latency directly | ❌ no direct knob | latency rises *naturally* with FH load (antennas/UEs/PRBs). `vrtsim.timescale<1` slows the **whole** sim, not FH only. |
| UE mobility → Doppler | ⚠️ proxy only | `max_Doppler` is **"CURRENTLY NOT IMPLEMENTED"** (sim.h:100). Time-variation is approximated by `forgetfact` (0=static … 1=fast change) or by feeding external time-varying CIR via `taps_client`/cirdb. No true velocity→Doppler. |

---

## The one big caveat: "CSI aging" is the wrong mechanism for **UL**

In this split, **UL channel estimation is done in-slot from the PUSCH DMRS** and used
immediately to equalize that same PUSCH. So UL *data demod* does **not** suffer
classic CSI aging from FH latency. FH latency degrades UL through two *indirect* paths:

1. **Timing loss** — if FH samples arrive after the DU's per-slot read deadline they
   are dropped → HARQ retransmissions. (This is exactly the bug fixed earlier in
   `oaioran.c`: the buffer reset was wiping late-arriving UL symbols → 99.9% retx.)
   Higher FH load ⇒ more late/dropped symbols ⇒ lower UL goodput.
2. **Stale link adaptation** — MCS/grant decisions use *past* SNR/BLER. Under a
   fast-varying channel + added FH delay, the chosen MCS mismatches the current
   channel ⇒ more BLER ⇒ lower throughput.

The "CSI aging" framing is cleanest for **DL precoding** (precoder computed from aged
UL/SRS estimates). If the goal is specifically UL, frame it as **"FH-latency-induced
timing loss + stale link adaptation,"** which the testbed *does* exhibit and measure.

So the **defensible** experiment is:
> sweep `iq_width` (quantization) × channel time-variation (`forgetfact`, mobility proxy)
> × delay spread (`ds_tdl`) × FH load (antennas / throughput), and measure UL goodput,
> FH load, and FH latency slack (TX budget). Expect: at high FH load + fast channel,
> heavy compression *helps* (less late-symbol loss) until quantization error dominates
> at the smallest `iq_width` → an optimum that moves with load/mobility.

---

## Evidence (file:line)

- Channel models TDL_A..E: `openair1/SIMULATION/TOOLS/sim.h:214-218, 251-255`
- Channel params: `noise_power_dB`, `ds_tdl` (delay spread), `forgetfact`, `ploss_dB`,
  `offset` — `sim.h:299-315`; sample format `ci-scripts/conf_files/channelmod_rfsimu.conf`
- `max_Doppler` NOT IMPLEMENTED: `sim.h:100-101`
- vrtsim chanmod / models `server_tx_channel_model` & `client_tx_channel_model`:
  `radio/vrtsim/README.md`; params `radio/vrtsim/vrtsim.c:83-90` (`chanmod`, `timescale`, `cirdb-path`, `taps-socket`)
- Multi-UE up to 16: `vrtsim.c` `num_ues`/`ue_id`, `MAX_NUM_UES`; no-chanmod multi-UE forces 1 gNB TX antenna: `vrtsim.c:1024` `AssertFatal(nbAnt==1, ...)`
- Antennas max 4: `radio/fhi_72/oaioran_ru.c:63 MAX_NUM_ANTENNAS 4`
- FH payload size: `oaioran_ru.c:1384` uncompressed `4·num_sc`; `:1386` compressed `(3·iq_width+1)·num_prb`, per antenna per symbol
- FH latency: vrtsim TX-budget histogram (`vrtsim.c` ~254-272, README); xran OWD `phy-f-1.0/fhi_lib/lib/src/xran_delay_measurement.c`
- Current run scripts do **not** enable chanmod → channel is ideal passthrough today.

---

## What to validate before trusting results

1. **chanmod realtime**: README warns chanmod can stop the UE connecting; may need
   `vrtsim.timescale < 1` (slower-than-realtime). Validate a single chanmod run first.
2. **FH actually bottlenecks**: confirm FH load (Mbps) and the TX-budget histogram
   move into the low bins (latency slack shrinking) as you scale antennas/throughput.
   If FH never saturates, the latency lever doesn't engage and the hypothesis can't show.
3. **Mobility is a proxy** (`forgetfact`), not a velocity. For a real mobility story
   you need external time-varying CIR (`taps_client`/cirdb) — bigger lift.
4. **Multi-UE** needs harness work (N UE processes + N CN subs). Prefer the
   antenna-count and throughput-demand levers first to raise FH load.
