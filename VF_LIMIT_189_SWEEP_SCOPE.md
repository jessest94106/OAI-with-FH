# VF Limit + 189 Sweep — Scope (2026-07-27)

**Goal**: enforce a *validated* 500 Mbps wire cap on the RU→DU FH VF while OAI/DPDK
drives it (= 25 Gbps effective at TS=0.02), then re-run the w1–16 IQ-width sweep at
189 PRB fixed noise with the cap provably in force, to locate (or rule out) the FH
congestion cliff.

**Why re-scoped**: the previous "capped" sweep is untrusted — the cap was verified via
kernel iavf (498/500) but never confirmed to survive OAI's DPDK VF init, and the in-run
cap read happened before RU init. w11 (101% nominal) and w12 (110%) ran clean, which is
consistent with either "cap silently cleared" or "load formula overestimates". One
instrumented run discriminates.

**Constraint (standing)**: no driver/kernel work — no bind/unbind, no modprobe, no
SR-IOV create/destroy. Only:
- user-run `post_reboot_prep.sh` (the lab's standard boot procedure),
- runtime `ip link set eno1np0 vf 0 max_tx_rate <N>` (netlink knob, reversible with 0),
- read-only counters (`ip link show`, `ethtool -S`).

---

## Phase 0 — Prereq (USER runs)
`sudo bash /home/jesse/oran_lab/post_reboot_prep.sh`
**Gate**: VFs 0000:06:02.0 / 0000:06:0a.0 present, MACs 64:66 / 64:68, bound
uio_pci_generic, CN containers Up. Read-only verify only.

## Phase 1 — Post-reboot sanity (no cap)
One 189 PRB w9 fixed-noise run (σ as in ledger REPRODUCE), 60 s.
**Gate**: 2/2 attach, PRACH ~56 dB. Confirms rebuilt `build/` binaries + fabric after reboot.
Fail → stop, debug before any cap work.

## Phase 2 — Cap mechanics under DPDK (the discriminating run)
Set `max_tx_rate 500` on eno1np0 vf0 **before** launch. One 189 w9 run with iperf
traffic. **During** steady traffic:
1. `ip link show eno1np0 | grep "vf 0"` — does `max_tx_rate 500` still show after DPDK VF reset?
2. `ethtool -S eno1np0 | grep port.tx_bytes` sampled twice 10 s apart → actual wire Mbps.
   (PF netdev stats don't see DPDK VF traffic; physical **port.** counters do.)

| Outcome | Meaning | Next |
|---|---|---|
| A: cap shows, wire ≈ 500, throughput drops | cap works under DPDK | Phase 4 directly |
| B: cap gone from `ip link` | DPDK VF reset clears PF state | re-apply mid-run, re-check; harness re-applies after RU init every run |
| C: cap shows, wire ≪ 500, throughput unchanged | load formula overestimates; cap never binding | Phase 3 first |

## Phase 3 — Measured load-vs-width curve (uncapped, only if outcome C)
Wire Mbps via port.tx_bytes at w4, w9, w14, w16 during steady traffic (reuse Phase-2
sampling; read-only; ~4 short runs). Output: measured curve replacing the
16-ant×all-PRB×every-symbol formula. Decide from it which widths can exceed 500 Mbps;
if even w16 < 500, report "no cliff reachable at 25 Gbps effective @189" and stop —
sweeping against a non-binding cap is vacuous.

## Phase 4 — Capped sweep w1–16 @ 189 fixed noise
- Cap applied per validated mechanism from Phase 2 (pre-launch or post-init re-apply).
- Per width: CN preflight (AMF "no SMF candidate" check → restart CN if hit), attach
  gate w/ retry, **180 s** iperf, report per-UE Mbps / MCS / true TBLER / preSNR.
- In-run per width (cheap, read-only): cap still present + one wire-rate sample.
- **N≥2** for widths whose measured load ≥ 90% of cap (w10/w12-style single-UE fault
  is the dominant error term; single points near the cliff are uncallable).
- Base on sweep189b.sh (has CN preflight, attach retry, fixed late-counter).

## Deliverables
- Verdict: cap-cleared vs formula-wrong (Phase 2 table row).
- Measured load-vs-width curve (if Phase 3 ran).
- Sweep table w1–16: Mbps / MCS / TBLER / wire-Mbps / cap-present, cliff position or
  "no cliff below 500 Mbps wire".
- FIXED_NOISE_PRACH_LEDGER.md updated with all rows + verdicts.

## Risks / cons
- **Intermittent per-UE degradation** (w10 UE0, w12 UE1): can fake a cliff. Mitigation
  N≥2 near cap; cost ~+30 min. Still the dominant error term.
- **Mid-run VF reset** could drop a re-applied cap between checks → per-width in-run
  check bounds the exposure to one width.
- **Port counters count C-plane+U-plane+eth overhead**: that's the real link load
  (feature), but numbers won't match pure-IQ formula; compare like-for-like only.
- **Wall clock**: 16 widths × ~7 min + repeats ≈ 2–2.5 h for Phase 4.
- **273 PRB stays paused** — out of scope here; revisit after 189 verdict.

## Out of scope
Driver/kernel changes of any kind; DPDK-level rate limiting; tc/qdisc on PF;
273 PRB; fixing vrtsim rx_samples_total diagnostic (separate small fix).
