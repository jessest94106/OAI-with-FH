# UE UL Feed-Path Optimization Plan (Option 3)

**Context (2026-07-19, rev-222):** 2-UE MU-MIMO campaign hit its software asymptote at
~390-404 sim-Mbps aggregate. Radio chain is validated done (MCS 26-28 @ 0.9-2.3% BLER,
chains 0); the binding constraint is the UE-side data feed: **~195 sim-Mbps per UE**
(~1 MB wall-second through tun → SDAP → PDCP → RLC). perf profile is diffuse: syscall
entry/exit + AMD SRSO mitigation thunks (~3.5%) + RT-scheduler/futex churn + memmove —
per-packet/per-hop cost, no single hotspot.

**Goal:** feed ≥250 sim-Mbps/UE (2 UEs × 250 = 500 ≈ radio capacity ~470-500).

**Code anchor:** `openair2/SDAP/nr_sdap/nr_sdap.c:107` `sdap_tun_read_thread` —
one `read()` per IP packet, then a synchronous per-packet `entity->tx_entity(...)`
(SDAP → PDCP → RLC) traversal. MAC pulls SDUs per-TB under entity locks
(`UL__actor` / `UEthread_0` futex churn in the profile).

---

## Stage 0 — Instrument (half a day, zero risk)

Direct feed measurement instead of inferring from TB padding:
- Rate-capped counters in `sdap_tun_read_thread`: packets/s, bytes/s, and the time
  split `read()`-wait vs `tx_entity` (two clock_gettime deltas, print every ~5 s).
- Mirror counter at MAC pull (bytes handed to TB build per slot).

Decision gate:
- `read()` wait dominates → cap is the saturator or tun qdisc (different fix).
- `tx_entity` dominates → Stages 1-2 are correct.
- Neither → MAC-pull-side locking → Stage 3.

## Stage 1 — Batch the tun reads (1-2 days, low risk, biggest expected win)

Today: `read(sock, rx_buf, NL_MAX_PAYLOAD)` = exactly one packet per syscall, at
~3000 syscalls+chain-traversals per wall-second (8500 B packets), each paying
syscall + SRSO-thunk tax.

Change: non-blocking fd + drain loop — read up to N (e.g. 32) packets into a
pre-allocated ring, process the batch, single `poll()` when empty.
(`IFF_MULTI_QUEUE`/vectored reads are the fancier variant; the drain loop is enough.)

- Files: `nr_sdap.c` read loop only; `tx_entity` call sites unchanged.
- Env gate: `OAI_UE_TUN_BATCH=N` (default off = stock single-read).
- Validation: Stage-0 counters + functional low-rate run (attach, ping, small iperf —
  no loss/reorder), then the standard N=3 clean-draw ladder.

## Stage 2 — Batch the SDAP→PDCP→RLC hand-off (2-4 days, medium risk)

Today per packet: SDAP header add → PDCP (entity lock, SN, [null-]cipher, memcpy)
→ RLC (entity lock, memcpy into SDU queue, accounting) → MAC signalling.
Two lock acquisitions + 2-3 copies per packet.

Changes (incremental):
1. `tx_entity_burst(entity, pkts[], n)`: take PDCP and RLC entity locks once per
   batch instead of once per SDU. Per-SDU semantics identical (SN assignment order
   preserved — PDCP reordering correctness).
2. Cut one copy: reserve SDAP/PDCP header headroom in the Stage-1 ring buffers so
   headers are written in place.

- Risk: locking discipline — hoist locks only, never change per-SDU logic.
- Validation: functional run + overnight stability soak + N=3 ladder.
- Combined Stage 1+2 estimate: +50-100% feed (per-packet cost collapses to memcpy floor).

## Stage 3 — MAC-pull / actor wakeup coalescing (only if 1-2 fall short)

Gated on Stage-0 evidence. If MAC-pull time dominates after Stages 1-2:
- Coalesce RLC→MAC buffer-status signalling: once per slot, not per SDU.
- Pre-reserve TB-build scratch (kills the `__memset_avx2` in `UL__actor`).
- Riskiest (RT threading) — last resort.

## Ground rules

- Env-gate every change, default = stock behavior.
- One stage per ladder batch; N=3 clean-draw-gated (gates: 2/2 attach, chains<50,
  minMCS≥18, UL_MB≥200); compare against the 404 baseline recipe.
- Build in `openairinterface5g/build/` (NOT cmake_targets/ran_build — rev-196 trap).
- 8-RX regression check before any commit.
- Revert path: git-clean per stage.

## Complementary levers (outside this plan)

- `mitigations=off` kernel boot param: ~+10-15% feed, security tradeoff, user decision.
- N_UE=3-4 MU phase: 3×195 = 585 feed ≥ radio capacity — but MU cosched machinery
  is 2-UE-pairing shaped; separate project.
- Related campaign state: memory `project_oran_iq_sweep.md` revs 195-222;
  commit plan `COMMIT_PLAN_UNCOMMITTED_TREE.md`.
