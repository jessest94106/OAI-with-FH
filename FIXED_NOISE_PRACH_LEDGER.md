# Fixed-Noise / PRACH Investigation Ledger

**Living doc. READ THIS FIRST, UPDATE IT AT THE END OF EVERY WORKING SESSION.**
Scope: the deterministic RX thermal-noise model (`VRTSIM_RX_NOISE_SIGMA`) that replaces the
target-SNR AGC, why it fails above 106 PRB, and the fronthaul-capacity work it blocks.

Last updated: 2026-07-26

---

## STATUS (one line)

**FIXED AND VERIFIED.** Root cause: the RU could not synthesize the fixed noise in real time at
122.88 Msps x 16 antennas, so UL samples were dropped and the UE signal never reached the merge
point. Replacing per-sample Box-Muller with a pre-scaled Gaussian table took the injector from
111 % to a few % of the wall budget and **189 PRB + fixed noise now attaches 2/2**.

| | before fix | after fix |
|---|---|---|
| merge census `max e0` | **0** (every sample, whole run) | **3867** |
| PRACH peak | 23.5 dB (== the 23.0 floor) | **56.4 dB** |
| attach | 0/2 | **2/2** |

`e0` 0 -> 3867 is the decisive number and is attributable to the noise-table fix ALONE — no
transmit-amplitude change can affect whether samples survive the shm ring. The PRACH peak figure
also includes the separate `nr_prach.c` amplitude fix (~27 dB), which is in the same build.

**Throughput SETTLED and it matches the AGC.** 189 PRB, sigma=7, w9, 180 s:
**310.1 Mbps, MCS 28/28, attach 2/2** vs the AGC baseline **310.5 Mbps, MCS 28/28** — a 0.13 %
difference. The fixed-noise model is now a drop-in replacement for the AGC at 189 PRB, with a
real absolute thermal floor instead of a signal-derived one. **The AGC lottery is dead at 189.**

Do NOT quote the first 60 s run (103 Mbps, MCS 17/11): that was an unconverged OLLA, not a
channel limit. Diagnostic — low MCS WITH low BLER (0.5 %/1.7 %) and only 1911 rounds vs ~4580.
A genuinely SNR-limited link pins MCS low AND sits at the BLER target. **Always run 180 s for a
throughput number**; 60 s is enough for attach/PRACH only.

## THE BUG

`radio/vrtsim/vrtsim.c:1613-1652` — `vrtsim_add_rx_thermal_noise()` performs **4 libm calls per
complex sample** (`log`, `sqrt`, `cos`, `sin`), inline and single-threaded, inside the RU's
`vrtsim_read` (call site :1824):

| config | cost/slot | wall budget @TS=0.02 | load |
|---|---|---|---|
| 61.44 Msps x 16 ant (106 PRB)     | 13.84 ms | 25.00 ms | **55 %** |
| 122.88 Msps x 16 ant (189/273)    | 27.71 ms | 25.00 ms | **111 %** |

One 0.5 ms slot = 25 ms wall at TS=0.02 (`vrtsim.c:605`), **independent of sample rate**, while
the work doubles. The function crosses 100 % exactly at the 106->189 boundary, and is skipped
entirely under AGC by the early return at `vrtsim.c:1615-1616` (`if (rx_noise_sigma <= 0) return;`).

Consequence chain: RU UL read thread slips -> `read_sample` falls behind the free-running ring
clock -> lag exceeds `CIRCULAR_BUFFER_SIZE` (`shm_td_iq_channel.c:37`; the tolerance HALVES too,
140 ms sim @61.44 vs 70 ms @122.88) -> `shm_td_iq_channel_rx` returns `CHANNEL_ERROR_TOO_LATE`
**leaving the destination untouched** -> `ul_combine_buffer`, reused across all 32 (u,a) reads
(`vrtsim.c:1758-1810`), retains stale zeros -> every antenna gets `+0`. RU `rxdata` is pure noise.

- **sigma-independence**: sigma is a single multiply at :1641; cost is byte-identical for
  sigma=1 and sigma=7. A step in *whether noise is synthesized at all*, not in its power.
- **Bandwidth axis**: the only bandwidth term is `nsamps`. 189 and 273 fail IDENTICALLY despite
  different PRB counts — the axis is **sample rate**, exactly as a compute-cost mechanism requires.
- **Why AGC works**: `rx_noise_sigma <= 0` -> early return -> RU pays zero -> real time restored
  at the same 122.88 Msps and same iqWidth.
- **Corroboration**: `[ORU PRACH RAW]` median slot energy = exactly 2*61440*7^2 with chi-squared
  agreement to 0.07 % on all 16 antennas — pure noise with ZERO added variance, which is what
  "+0 from a stale-zero buffer" predicts and what an attenuated signal does not.
- Consistent with the earlier in-tree note that gating noise out of slot 19 did NOT fix it —
  removing 1/20 of the cost leaves ~105 %.

Diagnostic that would have caught it is broken: `rx_samples_late` is incremented at
`vrtsim.c:1769` but `rx_samples_total += nsamps` lives at :2169, past the `return nsamps` at
:1829 that this branch takes; and the harness `pkill -9`s the RU so `vrtsim_end()` never prints.

## SUPERSEDED — the PRACH amplitude bug is REAL but is NOT this bug

`openair1/PHY/NR_UE_TRANSPORT/nr_prach.c:59,338` genuinely uses the dBm-valued `prach_tx_power`
as a linear Q15 amplitude, costing ~27 dB of PRACH margin. **A fix was written and built
(`nr_prach_tx_amp()`, dBm -> linear against AMP) and it is retained — it is a real upstream OAI
defect worth carrying.** But it CANNOT explain this failure: the defect is byte-identical in the
PASSING 106 runs, and +27 dB applied to a signal whose merge energy is exactly 0 is still 0.

**METHOD ERROR worth remembering:** the code claim was verified by hand, then treated as the
cause without checking whether it DISCRIMINATED between passing and failing runs. A defect present
equally in both arms can never explain the difference between them. This is the same error as the
sigma ladder and the iqWidth confound — three instances in one session.

## OLD HYPOTHESIS (kept for the record, DISPROVED)

`openair1/PHY/NR_UE_TRANSPORT/nr_prach.c`:
```c
const int16_t amp = prach_pdu->prach_tx_power;              // :59   <-- a dBm value
const c16_t Xu_t = c16xmulConstShift(Xu[offset], amp, 15);  // :338  <-- (Xu * amp) >> 15
```
`get_prach_tx_power()` (`openair2/LAYER2/NR_MAC_UE/nr_ra_procedures.c:42`) returns
`min(Pc_max, preambleReceivedTargetPower + pathloss)` — **dBm**, typically 13..22.
PUSCH data and DMRS are scaled by `AMP = 1<<AMP_SHIFT = 512` (`openair1/PHY/impl_defs_top.h:222-227`).
Per RE: PUSCH data 362, PUSCH DMRS 362–512, **PRACH 13–22**. That is 24–29 dB.

Measured preamble amplitude at the RU (from the in-tree `[ORU PRACH RAW]` probe,
`executables/nr-oru.c:295`), A_rms = sqrt(fft_energy/(2*dftlen)) per I/Q component:

| config | A_rms | vs sigma | outcome |
|---|---|---|---|
| 273 AGC       | 3.48  | noise = 0 in PRACH slots | PASS |
| 106 fixed s=7 | 2.57  | ~11 dB margin after processing gain | PASS |
| 273 fixed s=7 | <=1.10| below noise | FAIL |

Bandwidth coupling: `nr_prach.c:255` `dftlen = 2048>>mu`, then the `samples_per_subframe`
switch — `case 61440: dftlen<<=1` (2048), `case 122880: dftlen<<=2` (4096). Doubling the DFT
costs **-3 dB** per-sample preamble amplitude (orthonormal idft, 1/sqrt(dftlen)) and admits
**+3 dB** more noise into the window. That 6 dB swing is exactly what takes 2.57 under.

### Why this satisfies every constraint that killed the earlier hypotheses

- **sigma-independence**: the preamble sits at ~1–3 LSB, so even sigma=1 (1 LSB) is comparable.
  There was never a sigma that could win — which is why the sigma ladder was flat.
- **Why 3718 retries never climbed**: ramping is applied in the dBm domain and then clipped at
  `Pc_max` (`nr_ra_procedures.c:604-610`), so every retry emits an IDENTICAL amp. Power ramping
  is structurally incapable of moving the waveform.
- **Why AGC works**: it gates injection on `psig > 1.0`, leaving PRACH slots exactly zero, so an
  arbitrarily weak preamble still wins.
- **Why PUSCH is spared**: 512 vs ~20. sigma=7 never touches it — hence 177 Mbps at 106 while
  PRACH dies in the same run.

## THE FIX (applied, built, verified)

`radio/vrtsim/vrtsim.c` — pre-scaled Gaussian table replaces per-sample Box-Muller:
- `VRTSIM_NOISE_TAB_LOG2 23` -> 2^23 int16 = 16 MB, built once at init, **pre-scaled by sigma**
  so the hot path has no multiply: one load, one add, one saturate.
- Antennas walk it SEQUENTIALLY (prefetcher-friendly) from separated start offsets. A per-antenna
  *stride* would decorrelate but randomise access over 16 MB = a cache miss per sample (~80
  cycles), i.e. as expensive as the transcendentals being removed. Because every antenna advances
  by the same `2*nsamps` per slot, the offsets stay constant and no two antennas ever read the
  same entry at the same instant — spatial independence (what MRC array gain needs) is preserved.
- ponytail ceiling, named in-code: 34 ms of sim time at 122.88 Msps before an antenna's sequence
  repeats (32x the 1.07 ms the AGC noise pool already shipped with). Raise the LOG2 if a run ever
  needs longer decorrelation; cost is linear in memory.

## NEXT STEP

1. **IN FLIGHT**: IQ-width sweep w1..w16 @ 189 PRB, fixed noise, VF cap 500 Mbps (= 25 Gbps
   effective). Cliff predicted between w11 (23.9 Gbps, 96 %) and w12 (26.1 Gbps, 104 %).
   Every width is single-fragment at 189 (189*49 = 9261 B < 9600 MTU) so any roll-off is genuine
   congestion, not fragmentation — the confound that made the 273 sweep unreadable.
2. **273 PRB + fixed noise is still UNVERIFIED** — the run was started and cancelled before it
   produced a result. Same 122.88 Msps class as 189, so it is expected to pass, but not measured.
3. **Fix the broken real-time diagnostic** so this class of bug is visible next time: move
   `rx_samples_total += nsamps` before the early `return nsamps` at `vrtsim.c:1829`, or increment
   it in that branch. As it stands the RU's `Realtime issues: TX/RX %%` line would divide by zero,
   and the harness `pkill -9`s the RU before `vrtsim_end()` prints anyway — which is precisely why
   a 111 % real-time overrun left NO trace in any log.
4. Consider whether sigma=7 is the right floor at 189/273 or should be re-derived per carrier —
   note the reported SNR was 49.5 dB at BOTH 106 and 189 under sigma=7, and both reach MCS 28/28.

Root-cause workflow: run `wf_857fc409-f6b`, 2026-07-26, 30 agents, 22 candidates refuted,
1 survived. Six threads (vrtsim, UE PRACH TX, FH PRACH section, DU PRACH chain, config diff, log
forensics). The `e0=0` merge-census evidence was re-verified by hand against the logs.

---

## THE MATRIX

| Carrier | Sample rate | AGC (`rx-target-snr-db 30`) | Fixed noise (`VRTSIM_RX_NOISE_SIGMA`) |
|---|---|---|---|
| 106 PRB | 61.44 Msps  | works, 177 Mbps | **works**, 177.2 Mbps +/-0.2% (w2–w16) |
| 189 PRB | 122.88 Msps | works, 2/2, PRACH 42.6 dB, MCS 28/28, **310.5 Mbps** | **FAILS** 0/2, every width |
| 273 PRB | 122.88 Msps | works, 2/2, PRACH 41.9 dB, ~453 Mbps CDL-MU | **FAILS** 0/2, every width |

---

## ESTABLISHED (evidence-backed)

1. **IQ width is NOT the variable.** Same width passes at 106 and fails at 189:
   w6 -> 106 peak 44.7 dB / 189 peak 23.6 dB. w9 -> 106 peak 41.4–43.6 dB / 189 peak 23.5 dB.
   106 works across w2–w16. **This kills every BFP/compression explanation** — if mantissa width
   mattered, width would matter.
2. **Noise LEVEL is not the cause.** sigma 1 -> 7 is 17 dB of noise power and moves the outcome
   <1 dB (273: floor 21.5->23.0, peak 22.4->23.5, both 0/2). Any mechanism that is a smooth
   function of noise power is dead.
3. **The noise injector is behaving correctly.** Floor sorts by SAMPLE RATE, not PRB count:
   61.44 Msps -> 20.2 dB; 122.88 Msps -> 23.0–23.2 dB (189 and 273 identical). That is
   +2.8 dB for 2x rate = textbook 10*log10(2). Bandwidth scaling is right.
4. **BFP quantization floor is visible and physical at 106.** Floor falls monotonically with
   width — w1 28.7, w2 24.0, w3 22.5, w4 21.3, w5 20.6, w6+ flat 20.2 — i.e. quantization noise
   drops with mantissa bits until the sigma=7 thermal floor dominates from w6.
5. **The failure signature is wrong for noise.** In failing runs ALL ~3718 PRACH occasions read a
   flat ~23 dB and NOT ONE rises above it. The preamble is absent, not merely sub-threshold.
   Noise buries a peak gradually and PRACH power ramping should eventually win.
6. **The detection threshold is self-calibrating** —
   `openair1/SCHED_NR/nr_prach_procedures.c:127`:
   `prach_I0 = ((prach_I0*900)>>10) + ((max_preamble_energy*124)>>10)`
   i.e. an EWMA (alpha~0.121) of `max_preamble_energy` ITSELF, and detection is
   `energy > prach_I0 + prach_thres`. The threshold learns whatever floor you feed it.
   **This is why the sigma ladder was flat** and why the earlier "step response" reading was an
   artifact of the instrument, not a property of the radio.
7. **AGC only looks healthy because it runs PRACH at infinite SNR.** It gates injection on
   `psig > 1.0` (vrtsim.c ~1325), so empty PRACH occasions sit at literally 0.0 dB — 647 of 655
   occasions in the 189 AGC run. That pins the learned threshold at zero. Physically wrong; it is
   exactly why we want the fixed floor.
8. **189 PRB needs no bring-up.** On AGC it attached 2/2 first try: PRACH 42.6, SNR 63.5/63.5,
   MCS 28/28, 310.5 Mbps (96% of PRB-scaling from 273: 465*189/273 = 322). Derived config all
   correct first time: riv=24199, pointA=667728, prach_start=88, UE_SSB=1008, ADV=65536.

## ELIMINATED (do not re-open without new evidence)

- **IQ width / BFP compression** — see Established #1.
- **Noise level / sigma** — see Established #2.
- **Noise burying the preamble** — floors are 20.2 (106) vs 23.0 (189/273); 106 clears its own
  floor by 21 dB. The 189 floor is LOWER than 106@w1's 28.7 and still fails, so it is not a
  floor-height threshold either.
- **A second noise source.** `VRTSIM_UL_NOISE_STD` and `VRTSIM_UL_ATTEN_SHIFT` both exist (a
  3-bit shift would have been a tidy 18 dB) but were UNSET in every run — verified from ru.log.
- **"189 PRB is broken / needs bring-up"** — falsified, see Established #8. The three earlier
  "189 fails" results were: two fixed-noise runs, plus one that passed
  `--vrtsim.rx-target-snr-db=30` with `=` instead of a space (silently unparsed, PRACH read
  exactly 0.0 dB — that reading is the tell).
- **PRACH-slot noise gating as a fix** — TRIED AND REVERTED. Did not restore 273 (PRACH stayed
  23.5, 0/2) and REGRESSED 106 (177 -> 87 Mbps, attach 1/2).

Additionally eliminated by the `wf_857fc409-f6b` workflow (6 threads, adversarially verified):
- **Clipping / int16 saturation** anywhere in the merge — measured, does not occur.
- **Rate-dependent buffer truncation / overrun in vrtsim** — `batch_size` is rate-correct.
- **Noise added multiple times per sample** at larger nsamps — does not happen.
- **A return path bypassing the injector for PRACH** — none in this configuration.
- **BFP block exponent starving the narrowband preamble** — and, stated plainly by the FH thread,
  *no BFP mechanism can be non-monotonic in iqWidth*, which the data requires.
- **`prach_msg1_FrequencyStart` (DU) vs `prach_msg1_start` (RU) mismatch** — verified matched.
- **Band-edge PRACH parking at wide BW** — never used in any of these runs.
- **`prach_thres` BW-dependence** — it is a constant.
- **Wrong PRACH subcarrier / k-index wrap, wrong time window, Ncp / N_TA_offset scaling** — all
  ruled out arithmetically and empirically.
- **A hard-coded shift correct at 61.44 and wrong at 122.88 Msps** — searched for, not present.
- **The fixed-point DFT breaking oversampling/matched-filter invariance** — it does not.
- **TX-side failure** — ruled out; the preamble IS transmitted and DOES arrive. It is RX-side in
  the sense that it arrives ~11 dB under the noise, because it left the UE far too weak.

## OPEN

- **FH CONGESTION CLIFF — MEASURED AND CLOSED 2026-07-27** (full detail: `FH_CLIFF_106_PLAN.md`).
  106 PRB / 16 RX / fixed noise, converged 180 s runs:
  **No degradation below saturation; total failure at/above it.**
  - Throughput FLAT to 0.06% across 76/83/90/97% utilisation (177.8/177.8/177.9/177.8 Mbps,
    all MCS 28/28), then ZERO at 104%. No droop, no MCS backoff, no early loss, no warning.
  - Threshold bracketed **97% alive (cap200 w13) / 101% dead (cap150 w10)** — i.e. at nominal
    capacity within resolution. Finer sampling is not possible: cap quantises to 50 Mbps and
    IQ width is an integer, so no (cap,width) pair lands in 97.1–101.2% at 106 PRB.
  - Cliff MOVES with the cap (w13/w14 at cap 200 -> w9/w10 at cap 150) = mechanism confirmed
    as FH congestion, not RU overrun or per-UE fault (those would stay at a fixed width).
  - Failure signature discriminator: dead + PRACH ~20 dB = FH congestion (UE signal erased);
    dead + PRACH ~56 dB = CN/attach failure (radio fine). Caught a false w13 death this way.
  - Throughput is INDEPENDENT of IQ width while alive — width is a transport parameter, it
    changes wire bytes, not air bits. Only decides whether the FH can carry the samples.
  - CAVEAT: constant-rate paced source (the RU). A burstier source could fail below 100%
    average; untested.
- **VF limit + 189 capped sweep** — scoped in `VF_LIMIT_189_SWEEP_SCOPE.md`; Phases 0–2 DONE
  2026-07-27. **MILESTONE VERDICT: the VF software cap WORKS under DPDK** (Outcome C + clamp proof):
  - Cap SURVIVES OAI's DPDK VF init — `max_tx_rate 500Mbps` present in mid-run readback.
  - Cap ENFORCES on the DPDK path — mid-run drop to 150 pinned wire at 154 Mbps (2 samples);
    restore to 500 gave a 367 Mbps backlog-drain burst then settle. Runtime knob, no rebind.
  - Earlier "capped" runs showed nothing because the cap never bound: **real w9 wire load is
    252 Mbps** vs formula's ~84%-of-500 prediction (~1.7x over-prediction — formula ignored
    TDD split + real section/packet layout). Measure, don't compute, FH load.
  - **FH U-plane load is traffic-independent**: wire flat at 252 Mbps with iperf on or off
    (RU streams IQ every UL symbol; 120 sim Mbps of user traffic = 2.4 Mbps wall at TS=0.02).
    One mid-run `port.tx_bytes` delta per width fully characterizes load. PF netdev stats do
    NOT see DPDK VF traffic; use `ethtool -S eno1np0 | grep port.tx_bytes`.
  - Post-reboot runs healthy: Phase 1 sanity (attach 2/2, PRACH 56.4) and Phase 2 capped-500
    (311 sim Mbps agg, MCS 28/28, PRACH 55.7) — both match pre-reboot reference.
  - **A binding cap is a WALL, not a slope**: 25 s at cap 150 (61% of natural 252) desynced
    both UEs (108 out-of-sync in du.log), goodput froze, MCS collapsed to 3,0; restoring the
    cap did NOT recover them within the run. Matches the FH-loss per-TB-catastrophic finding.
    Expect the Phase-4 "cliff" to look like attach/session collapse, not reduced Mbps.
  - **SHAPER CALIBRATION (testpmd only, no OAI, 2026-07-27)** — `nic_shaper_test.sh`:
    linear and accurate over two decades; error is a constant *scale factor*, not an offset:
    cap 100/250/500/1000/2000 -> 102/257/514/1028/2056 Mbps (+2% each). Frame-size sweep at
    cap 500: 1024B -> +2.8%, 1500B -> +3.0%, 64B -> +8.8% (per-packet overhead; the 4000/8000
    rows in framesize_cal.txt are INVALID — testpmd fell back to 64B, mbuf 2048 < 4000).
    Single-core testpmd offers only 6.4 Gbps — the box cannot fill 10G naturally, but the
    shaper works far below that, so cap-setting does not depend on host TX capability.
  - **CAP QUANTIZATION (confirmed 7/7, `quant_test.txt`)** — i40e rounds `max_tx_rate`
    DOWN to a 50 Mbps step, then overdelivers ~3%:
    `wire_Mbps = floor(cap/50) x 50 x 1.03`. Evidence: 400/425/449 -> 412; 450/475/499 -> 464;
    500 -> 515. Earlier "perfectly linear +2%" was an artifact of only testing multiples of 50.
    **Only multiples of 50 are meaningful cap values.**
  - **CAP CALIBRATION (corrected — the earlier "cap 485" was WRONG, 485 rounds to 450)**:
    `effective_Gbps = floor(cap/50) x 50 x 1.03 / 20`. Achievable rungs (~2.6 Gbps apart):
    cap 200 -> 10.3 | 250 -> 12.9 | 400 -> 20.6 | 450 -> 23.2 | **500 -> 25.75** | 550 -> 28.3.
    No cap yields exactly 25.0 Gbps; **use cap 500 and report 25.75 Gbps effective**.
  - **NIC LOAD SWEEP, OAI ISOLATED (`load_sweep.txt`, `hostrx_confirm.txt`)** — DPDK both
    ends (txonly 06:02.0 -> rxonly 06:0a.0, `--eth-peer` REQUIRED or the VEB filters every
    frame and the app receives 0 while port counters look perfect):
    | cap | 50 | 200 | 600 | 1000 | 2000 | 3000 | 5000 | none |
    | wire Mbps | 52 | 206 | 619 | 1031 | 2064 | 3096 | 5160 | 6376 |
    | kpps | 4.3 | 17.2 | 51.5 | 85.7 | 171.5 | 257.3 | 429.3 | 530.0 |
    Delivered = 1.032 x cap at EVERY point over a 100x range — proportional, no knee, no
    droop. Wire loss <= 0.02% everywhere (sign flips => counter skew, i.e. zero).
    **Ceiling is the generator, not the NIC: ~530 kpps / 6.4 Gbps per testpmd core @1500B.**
    Host-RX at max offer (495 kpps sustained 30 s): app drained 13,873,871 pkts,
    NIC ring-full drops 11,684 = **0.084% host loss** — the receiving host keeps up.
    TRAP: testpmd's periodic app stats are sampled asynchronously and skew +-2%, and gave a
    bogus "42% host loss" at max rate; `rx_missed`/`RX-dropped` (HW) is the only authority —
    2.5M implied drops would have shown there and did not.
  - **NEAR/OVER THE LIMIT (`limit_region.txt`)** — greedy source, utilisation 73 -> 145%:
    | util | 73 | 82 | 91 | 96 | 99.9 | 105 | 111 | 121 | 145 |
    | delivered Mbps | 5969 | 5967 | 5969 | 5971 | 5970 | 5672 | 5367 | 4953 | 4129 |
    | wire loss | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |  (all <=0.02%, sign flips = skew)
    | rx_missed | 0 at EVERY point |
    Below the limit: flat, 0.08% spread, **no droop, no early loss, no ring pressure** — the
    NIC gives NO advance warning of saturation. Above: delivery pins exactly at cap x 1.03
    (5672/5665, 5367/5356, 4953/4944, 4129/4120 — all within 0.15%) and STILL loses nothing;
    the excess is refused at the sender, never discarded in flight. Deterministic queueing:
    fine until it isn't. Operational consequence: no NIC counter predicts an FH cliff —
    utilisation must be computed from measured load vs cap, not inferred from error counters.
    CAVEAT: greedy source, so this is the shaper's hard behaviour; a PACED deadline source
    (the real RU) sees queue growth before average rate reaches the cap — unmeasured, would
    need a rate-controlled sender (custom DPDK app, or kernel-bound VF + `iperf3 -b`).
    TRAP: offered rate is NOT a constant of the box — it fell 6370 -> 5969 Mbps once the
    receiver actually consumed packets (4 cores, shared CPU). Re-measure it per setup;
    utilisation labels computed from a stale figure are ~5 points optimistic.
  - **DROPS AND LATENCY (`drop_latency.txt`)**: the NIC does NOT drop and the wire does NOT
    lose — eno1np0 tx == enp5s0f1np1 rx within +-0.004% at 154 / 464 / 6371 Mbps. The shaper
    BACKPRESSURES (tx_burst returns short); packets die inside the *sending application*.
    testpmd's huge TX-dropped is its own spin-discard, NOT a NIC counter — do not cite it.
    Queueing delay at full 512-desc ring = 512 x frame x 8 / rate: **12.7 ms @464, 31.7 ms @154**
    vs a Ta4 window of tens-to-hundreds of us => any binding cap is ~100x too slow. Explains
    wall-not-slope. Below the cap the ring stays near-empty (us-scale), hence capped-but-
    non-binding runs are indistinguishable from uncapped. (Geometry-derived, not timestamped.)
  - **MEASURED FH LOAD @189 PRB, 16 ant** (port.tx_bytes, traffic-independent):
    w9 = 252 Mbps = 12.6 Gbps eff; w16 = 432 Mbps = 21.6 Gbps eff.
    Linear fit: `load_Mbps ~= 20.6 + 25.7 x width`, i.e. `eff_Gbps ~= 1.03 + 1.29 x width`.
    => **at 189 PRB no IQ width reaches 25 Gbps** (w16 peaks at 21.6). A 25 Gbps cap can
    never bind here; the sweep as scoped is vacuous. To bind at 25 Gbps need ~273 PRB
    (load x 1.44 -> w16 ~= 31 Gbps eff) — which is exactly the paused 273 thread.
  - **MEASUREMENT VALIDATED AGAINST FIRST PRINCIPLES (2026-07-27)**. Continuous-UL payload
    for Cat-A / 16 RX / 189 PRB / 30 kHz / 16-bit I+Q:
    `2268 SC x 32 bit x 28000 sym/s x 16 ant = 32.52 Gb/s`. That is the **100%-UL** number.
    Our TDD pattern (`du_test.conf:67-71`, periodicity enum 5 = 2.5 ms = 5 slots @30 kHz:
    1 DL + special[6D/4U] + 3 UL) carries UL in **46 of 70 symbols = 65.7%**:
    `32.52 x 0.657 = 21.37 Gb/s` predicted vs **21.6 Gb/s measured** (+BFP exponent byte
    +eCPRI/Eth/IFG) — **agreement ~1%**. So the wire measurement is CORRECT, and the reason
    189 PRB never saturates 25 Gbps is the TDD duty cycle, not a broken cap or a bad counter.
    Corollary: 273 PRB -> 32.52 x (273/189) x 0.657 = **30.9 Gb/s > 25** (wall 618 Mbps), so
    cap 500 binds there. A 100%-UL pattern at 189 would also exceed 25 (32.5).
- **Intermittent single-UE degradation** (w10 UE0 285.3, w12 UE1 258.1; load-independent;
  w12 ≈ AGC 56%-load run within 1 Mbps) — dominant error term.
  **N=3 DONE 2026-07-28 @106/w9: 155.5 (MCS 23,28) / 177.7 (28,28) / 177.6 (28,28)
  => occurrence rate 1 in 3, cost -12.5%.** Signature: ONE UE pinned several MCS below
  the other, load-independent, no PRACH/FH symptom (PRACH 55.7-56.4 dB in all three).
  Root cause still unknown. Practical rule: any single run showing an asymmetric MCS pair
  is suspect — repeat before recording. This has now impersonated a real effect 3x.
- **vrtsim RU diagnostics were broken three ways** — FIXED 2026-07-28 (`vrtsim.c`,
  submodule commit bce1e222fe): (1) `vrtsim_read` returns early in the multi-UE branch
  (`:1915`) skipping `rx_samples_total`, so on the ONLY path this lab runs the realtime
  denominator was **zero**; (2) `rx_samples_late` counts per sub-read vs total per call =
  32x unit mismatch at 2 UEs x 16 ant (added `rx_subreads`); (3) the end-of-run summary is
  in `vrtsim_end()`, which never executes because the harness SIGKILLs — vrtsim's final
  statistics have never been visible in any run to date. Any past reasoning that cited the
  RX realtime percentage is void.
- **TRAP: `run_ru.sh:112` passes an explicit env allowlist** (`sudo -E ... env VAR=...`).
  Unlisted variables are dropped **silently** — the feature does nothing while the run looks
  healthy. Add every new RU-side knob to that list.
- ~~273 + fixed noise never verified post-fix~~ **CLOSED 2026-07-27**: 273 w9 fixed noise
  (sigma=7) ATTACHES post noise-table fix — UEs up, UL saturation running (pre-fix it failed
  4/4 with PRACH peak 23.5 vs floor 23.0). Wire load **364 Mbps = 18.2 Gbps eff, 12164 pps,
  avg frame 3747 B** — exactly the 364 Mbps predicted by scaling 189 w9 (252) x 273/189.
  **PRB scaling is linear and exact**, so `wall_Mbps = 15.0 x width x (PRB/106)` is trusted.
- **106 @ w1 shows the identical stale-zero signature** (floor 28.7 == peak 28.7, 0 Mbps) —
  consistent with the same overrun mechanism reached from the quantization side, but not
  separately confirmed.
- Secondary defects surfaced by the workflow, real but NOT the discriminator — revisit after the
  fix lands, do not chase now:
  - FD noise delivered to the detector is 7.0–9.3 dB above what a unitary DFT + 12-symbol
    accumulation of sigma=7 predicts (`radio/fhi_72/oaioran.c:399-403`, non-saturating int16 `dst`).
  - Deterministic sigma-independent negative DC-bin spur ~0.5 LSB * sqrt(dftlen); the PRACH bin
    extraction wraps DC (k=4020, dftlen=4096).
  - Latent 16-RX hazard: `prach_ifft` is int32 and accumulates squaredMod over ALL RX antennas
    BEFORE `>>log2_ifft_size` (`nr_prach.c:634-635,650,654`) — 16 RX costs 12 dB of headroom;
    on overflow it goes negative into `dB_fixed_times10`. Not triggered in these runs.
  - Box-Muller injector cost: 4 libm calls per complex sample, inline and single-threaded in
    `vrtsim_read`, O(nsamps x nbAnt) = 61440 x 16 per slot at 122.88 Msps. Watch for RU overrun
    at wide carriers once PRACH works.
  - Instrumentation defect: the multi-UE+chanmod branch returns early at `vrtsim.c:1829`,
    bypassing `rx_samples_total += nsamps` at :2169 while `rx_samples_late += nsamps` IS
    incremented at :1769 — so the late/total ratio is misleading in exactly the failing config.
- Port-1 / second-UE MCS asymmetry survives a symmetric noise floor (e.g. 189 AGC w6: MCS 28/21,
  BLER 0.04%/12.4%).
- Fronthaul congestion has never actually been observed — every capped run so far sat at
  10–56% utilisation.

---

## FULL FACTORIAL — every fixed-noise run on disk (sigma > 0)

`floor` = modal `[RAPROC] ... energy X dB` (occasions with no preamble); `peak` = max over run.
Mbps is the attach proxy — the `Generate Msg2|RA-Msg3` grep is broken and reads 0 even for
runs doing 177 Mbps. **floor == peak means the preamble never appeared = hard fail.**

| dir (multiue_2026...) | PRB | iqw | sigma | floor | peak | Mbps |
|---|---|---|---|---|---|---|
| 0726_025504 | 106 | 1  | 7  | 28.7 | 28.7 | 0.0 FAIL |
| 0726_031906 | 106 | 1  | 7  | 28.7 | 28.7 | 0.0 FAIL |
| 0726_051605 | 106 | 2  | 7  | 24.0 | 45.2 | 27.9 |
| 0726_082719 | 106 | 2  | 7  | 24.0 | 40.6 | 27.8 |
| 0726_052404 | 106 | 3  | 7  | 22.5 | 41.9 | 68.4 |
| 0726_084036 | 106 | 3  | 7  | 22.4 | 42.5 | 66.1 |
| 0726_034508 | 106 | 4  | 7  | 21.3 | 42.4 | 117.7 |
| 0726_085005 | 106 | 4  | 7  | 21.3 | 42.2 | 150.8 |
| 0726_053820 | 106 | 5  | 7  | 20.6 | 41.7 | 130.2 |
| 0726_035603 | 106 | 6  | 7  | 20.2 | 44.7 | 177.2 |
| 0726_054734 | 106 | 7  | 7  | 20.2 | 43.1 | 118.6 |
| 0726_075747 | 106 | 7  | 7  | 20.2 | 43.7 | 178.1 |
| 0726_040758 | 106 | 8  | 7  | 20.2 | 42.1 | 177.2 |
| 0726_014141 | 106 | 9  | 7  | 20.2 | 43.6 | 117.0 |
| 0726_015051 | 106 | 9  | 16 | 20.8 | 43.0 | 150.1 |
| 0726_042124 | 106 | 9  | 7  | 20.2 | 41.4 | 177.3 |
| 0726_121925 | 106 | 9  | 7  | 20.2 | 39.9 | 87.3 |
| 0726_060426 | 106 | 10 | 7  | 20.0 | 43.7 | 177.4 |
| 0726_043716 | 106 | 11 | 7  | 20.2 | 43.5 | 177.2 |
| 0726_061421 | 106 | 12 | 7  | 20.2 | 42.0 | 109.9 |
| 0726_081024 | 106 | 12 | 7  | 20.2 | 44.0 | 168.7 |
| 0726_062315 | 106 | 13 | 7  | 20.2 | 43.6 | 177.1 |
| 0726_063932 | 106 | 14 | 7  | 20.2 | 41.9 | 138.1 |
| 0726_065212 | 106 | 15 | 7  | 20.2 | 42.4 | 177.5 |
| 0726_070307 | 106 | 16 | 7  | 20.2 | 42.9 | 177.1 |
| 0726_091629 | 189 | 6  | 7  | 23.2 | 23.7 | 0.0 FAIL |
| 0726_094352 | 189 | 6  | 7  | 23.2 | 23.6 | FAIL |
| 0726_100626 | 189 | 9  | 2  | 22.6 | 22.9 | 0.0 FAIL |
| 0726_175637 | 189 | 9  | 7  | 23.0 | 23.5 | FAIL |
| 0726_105403 | 273 | 9  | 7  | 23.0 | 23.5 | 0.0 FAIL |
| 0726_112735 | 273 | 9  | 1  | 22.3 | 22.4 | 0.0 FAIL |
| 0726_115238 | 273 | 9  | 3  | ?    | ?    | 0.0 FAIL |
| 0726_115451 | 273 | 9  | 7  | 23.0 | 23.5 | 0.0 FAIL |

AGC reference points: 273 w9 -> floor 0.0, peak 41.9, PASS. 189 w9 -> floor 0.0, peak 42.6, PASS
(`0726_172703`).

## FRONTHAUL CAPACITY (blocked on the above)

Only one capacity point completed before the sweep was cleared, and it is on **AGC**, so treat it
as provisional — it must be re-run under fixed noise once the fix lands:

- 189 PRB, w6, VF cap 500 Mbps (= 25 Gbps real-time equiv at TS=0.02): **257.2 Mbps**, 2/2,
  MCS 28/21, BLER 0.04%/12.4%, late=31, load 14.1 Gbps = 56% of budget. Not congestion.

Why 189 is the right carrier for this: the 25G cliff lands at w12 (w11 23.9 / w12 26.1 Gbps incl
DL+hdr) AND every width is single-fragment at 189 (189*49 = 9261 B < 9600 MTU), so w6–w14 has no
fragmentation confound — unlike 273, which fragments above w11.

---

## TRAPS (each of these cost a wrong result)

- **`VRTSIM_UE_XARGS` args must be SPACE-separated.** `--vrtsim.rx-target-snr-db=30` is silently
  unparsed; the tell is PRACH reading exactly 0.0 dB. Use `"--vrtsim.rx-target-snr-db 30"`.
- **`ninja nr-softmodem` does NOT rebuild `vrtsim.c` or `oaioran.c`** — they are dlopen'd modules
  (`libvrtsim.so`, `liboran_fhlib_5g.so`). Build those targets and verify mtime.
- **THERE ARE TWO BUILD TREES AND THE HARNESS USES THE NON-OBVIOUS ONE.** `run_du.sh:8` and
  `run_ru.sh:8` both set `BUILD_DIR="${OAI_DIR}/build"`, i.e.
  `oaicicd/test_dir/openairinterface5g/**build/**` — NOT the conventional
  `cmake_targets/ran_build/build/`. Both directories exist, both contain a `libvrtsim.so`, and
  building the conventional one leaves the harness loading a stale library with NO error and NO
  warning. Always: `cd $OAI_DIR/build && ninja <target>`, then `ls -l` the artifact there.
  Cost when missed: one fully invalid test run that looked completely normal.
- **`pkill -f PATTERN` kills your own shell** whenever PATTERN appears literally in the command
  line you are typing (heredocs count). Bracket EVERY pattern — `nr-softmode[m]`, `ts00[5]\.sh` —
  or better, check `pgrep` first and skip the kill when nothing is running.
- **Env vars must be in the `run_du.sh` / `run_ru.sh` whitelist** or they are silently dropped —
  this invalidated a whole rho-bypass A/B.
- **`prach_I0` is not a noise measurement**, it is an EWMA of the energy it gates. Sweeping a
  parameter the detector adapts to yields a flat line that reads as "not the cause" — which is
  the same flat line you would get if it were.
- **Attach grep `Generate Msg2|RA-Msg3` is broken** — reads 0 even on healthy runs. Use throughput.
- **SMF IP-pool exhaustion masquerades as box endurance**: healthy PRACH but
  `PDU Session Establishment REJECT`, UE IPs climbing. Fix: `docker restart oai-smf oai-upf oai-amf`.
- **★ AMF LOSES ITS SMF AND EVERY RUN SILENTLY SCORES 0/2.** Signature: PRACH strong (55+ dB),
  RRC completes, **`Registration Accept` received**, UE sends `PduSessionEstablishRequest` ONCE
  (no retry, no timer expiry), then nothing — no `oaitun`, so the harness scores 0/2. Looks
  exactly like a radio/IQ-width failure and is not. The tell is in the AMF, not the gNB:
  `[amf_sbi] [error] SMF Selection, no SMF candidate is available`
  and **zero** `UE IPv4 Address` lines in the SMF for the run's time window. Note the SMF logs
  0 REJECTs, because it never sees the request at all — so "no REJECTs" does NOT mean the CN is
  healthy. Both UEs fail together (shared CN), and it persists across every subsequent run, so it
  reads as "everything above width N is broken". Fix: `docker restart oai-smf oai-upf oai-amf`,
  then confirm `SMF has successfully registered to NRF` is recurring (~10 s heartbeat) and that
  `no SMF candidate` count is 0.
  **ALWAYS check this before attributing an attach failure to the radio.** Cost when missed: an
  entire IQ sweep (w3/w4/w5 rows all invalid) plus ~90 min of runtime.
  Clock trap while checking: container logs are in a DIFFERENT timezone from the host (observed
  +9 h). Convert with `docker logs --timestamps ... | date -d "$ts"` before mapping events to run
  windows — mis-aligning them made w2's successful sessions look like w3/w4's.
- **Throughput must be measured over the final 4 samples consistently** — a tail-N window on runs
  that started at different times produced a w16 reading with FEWER total bytes than w15.
- **Median scripts must exclude failed runs**, not average 0.0 into the sample.
- **Do not put a script's own name in a monitor command string** — the script's `pgrep -f` wait
  loop will match the monitor and self-deadlock. Use the `name[.]sh` bracket trick.
- **Verify the baseline attaches before spending hours on a sweep.** Two multi-hour sweeps were
  launched on configs that could not attach.

## REPRODUCE

Working fixed-noise run (106 PRB):
```bash
OAI_UL_AVG_AGG=2 ADV=32768 BW=106 IQ_WIDTH=9 COMP_METH=1 \
N_UE=2 TS=0.02 CHANMOD=1 CHAN_TYPE=CDL_A CHAN_DS_US=0.1 NB_ANT_RX=16 \
VRTSIM_CDL_UE_AZ_DEG=0,90 OAI_UL_MU_COSCHED=1 OAI_UL_MU_PORTS=1 OAI_UL_MU_IRC=1 \
UESS_AGG=0,8,8,4,2 PER_UE_WAIT=700 IPERF_SECONDS=180 \
VRTSIM_RX_NOISE_SIGMA=7 bash /home/jesse/oran_lab/run_multi_ue.sh
```
Working AGC run (189 PRB) — swap the last env line for:
```bash
ADV=65536 BW=189 VRTSIM_UE_XARGS="--vrtsim.rx-target-snr-db 30"
```

Extract the PRACH diagnostics from any run:
```bash
D=/home/jesse/oran_lab/logs/multiue_YYYYMMDD_HHMMSS
grep -ao "energy [0-9.]* dB" $D/du.log | awk '{print $2}' | sort | uniq -c | sort -rn | head  # floor
grep -ao "energy [0-9.]* dB" $D/du.log | awk '{print $2}' | sort -g | tail -1                # peak
grep -ao "RX thermal noise sigma [0-9.]*" $D/ru.log | head -1                                 # sigma
```
