# Fake Non-Realtime FH Backend Plan

## Goal

Build a fake RU-DU fronthaul backend for OAI that keeps the real OAI process split, but removes wall-clock real-time deadlines from the fronthaul path.

The target experiment is not "can this host run O-RAN 7.2 in real time." The target experiment is:

```text
increased FH load or injected FH delay
  -> delayed UL observations / delayed control-loop information
  -> CSI, HARQ, and scheduling decisions use older information
  -> uplink throughput changes
```

The backend should let us measure uplink throughput while preserving a real OAI UE, OAI RU, and OAI DU split.

## Non-Goals

- Do not measure NIC, DPDK, or xRAN real-time capacity.
- Do not emulate every O-RAN 7.2 packet format in the first version.
- Do not depend on symbol callback deadlines for the first version.
- Do not drop samples because wall-clock CPU missed a deadline.
- Do not replace OAI MAC/PHY/scheduler behavior with a custom simulator.

## Current Problem

The current `fhi_72` xRAN/DPDK path is real-time bound. Even at 24 PRB / mu1, the RU reports:

```text
Packets not processed by the application layer (application layer too slow): 14336
```

This is an implementation-capacity failure. It can hide the intended experiment because the system drops FH packets before we can cleanly observe latency/control-loop impairment.

For this research goal, packet drops from missed wall-clock deadlines are noise unless explicitly enabled as a separate experiment mode.

## Recommended Architecture

Keep `nr-oru` and `nr-softmodem` as separate OAI processes, but replace the RU-DU `fhi_72` backend with a fake non-realtime backend.

```text
nr-uesoftmodem
    |
  vrtsim
    |
nr-oru
    |
fakefh shared-memory or unix-socket backend
    |
nr-softmodem DU
```

This preserves:

- real OAI UE stack
- real OAI RU process
- real OAI DU/gNB process
- real OAI MAC/PHY scheduling and decoding path as much as practical
- RU-DU process boundary
- controllable FH latency/load model

This removes:

- DPDK polling load
- xRAN wall-clock symbol deadlines
- NIC driver behavior
- real-time packet-drop collapse

## Timing Model

The fake backend should operate in simulated radio time, not wall-clock time.

Each message carries:

- frame
- slot
- symbol range where relevant
- timestamp in samples
- direction: DL or UL
- payload type
- IQ payload or compact control payload

The peer blocks until the requested simulated-time data is available. Simulated time advances only when the pipeline can make progress.

This means a run can be slower or faster than real time, but the radio-time ordering remains valid.

## Latency Injection Model

Inject latency in radio slots first, not host milliseconds.

Example:

```text
fakefh.delay_ul_slots = 0, 1, 2, 4, 8
fakefh.delay_dl_slots = 0, 1, 2, 4, 8
fakefh.jitter_slots   = optional
fakefh.queue_model    = fixed_delay | byte_rate | bounded_queue
```

For the first experiment, use deterministic delay:

```text
deliver_time_slot = original_slot + delay_slots
```

Later, add load-dependent delay:

```text
serialization_delay = payload_bytes / fake_fh_capacity_bytes_per_slot
queue_delay         = bytes_already_queued / fake_fh_capacity_bytes_per_slot
deliver_time        = original_time + serialization_delay + queue_delay
```

This lets us sweep fake FH capacity and observe throughput degradation caused by queued or stale information.

## What "FH Latency" Should Mean

For this experiment, FH latency is a radio-time delay between the producer side and consumer side of the split.

Examples:

- RU receives UL IQ for slot `N`, DU sees it at slot `N + D`.
- DU generates DL/control for slot `N`, RU sees it at slot `N + D`.
- CSI or decoded UL information becomes available to scheduler later.

The important thing is not whether the wall clock spent 200 us or 20 ms. The important thing is how many radio slots old the information is when OAI uses it.

## Payload Scope

Start with a minimal IQ-forwarding backend.

### UL Path

RU side:

1. `nr-oru` receives UE uplink samples from `vrtsim`.
2. RU packages timestamped UL IQ into fake FH messages.
3. fake FH queues messages according to configured delay/load.
4. DU receives the delayed UL IQ.
5. DU runs normal OAI PRACH/PUSCH processing.

### DL Path

DU side:

1. DU produces downlink IQ/control-related output through its radio-device interface.
2. fake FH queues messages according to configured delay/load.
3. RU receives delayed DL IQ.
4. RU writes DL IQ to `vrtsim` for UE reception.

## Open Design Question: Interface Level

There are two plausible integration levels.

### Option A: Radio Device Style Backend

Implement a new backend similar to `vrtsim`/`rfsimulator` using `openair0_device_t` hooks:

- `trx_start_func`
- `trx_read_func`
- `trx_write_func`
- `get_timestamp`
- `trx_end_func`

Pros:

- simpler MVP
- uses an established OAI plugin pattern
- easier to make non-realtime/blocking
- easier to instrument bytes, slots, and delays

Cons:

- less faithful to the existing `fhi_72` xRAN integration
- may bypass some O-RAN-specific C-plane behavior

### Option B: Fake `fhi_72` Transport

Keep more of the `fhi_72` structure, but replace xRAN/DPDK packet transport and timing with fake queues.

Pros:

- closer to current RU-DU 7.2 split path
- can later emulate C-plane/U-plane split more accurately

Cons:

- higher implementation risk
- existing code has symbol-deadline assumptions
- harder to make fully non-realtime
- more likely to preserve the current failure mode

Recommendation: start with Option A. If the experiment proves useful, add specific `fhi_72` semantics later.

## Backend Name

Use a new backend name such as:

```text
fakefh
```

Expected config shape:

```conf
fakefh = {
  role = "ru";              # ru or du
  channel = "fakefh_ru_du";
  realtime = "no";
  delay_ul_slots = 0;
  delay_dl_slots = 0;
  capacity_mbps = 0;        # 0 means unlimited
  queue_limit_slots = 0;    # 0 means unbounded for first version
  stats_period_ms = 1000;
};
```

## Required Counters

The backend should log:

- UL bytes transferred
- DL bytes transferred
- UL IQ samples transferred
- DL IQ samples transferred
- simulated frames processed
- simulated slots processed
- wall-clock elapsed time
- simulated-time / wall-clock ratio
- configured UL/DL delay in slots
- observed queue delay in slots
- max queue depth in bytes and slots
- drops, if explicitly enabled

Throughput should be reported in two forms:

```text
radio-time throughput = payload_bits / simulated_radio_seconds
wall-time throughput  = payload_bits / wall_clock_seconds
```

For the research question, radio-time throughput is the primary metric.

## OAI Metrics To Collect

From OAI logs or added counters:

- UE attach / RA success
- Msg1, RAR, Msg3, Msg4 success
- UL MAC throughput
- UL PDCP throughput if user-plane traffic is active
- PUSCH MCS
- PUSCH BLER
- HARQ retransmissions
- timing advance behavior
- CSI/CQI/RI/PMI age if available
- scheduler selected grants per slot

## Experiment Matrix

Start with a stable baseline:

```text
mu1, 24 PRB, 1 UE, no channel model, delay_ul_slots = 0, delay_dl_slots = 0
```

Then sweep:

```text
delay_ul_slots = 0, 1, 2, 4, 8
delay_dl_slots = 0
```

Then:

```text
delay_ul_slots = 0
delay_dl_slots = 0, 1, 2, 4, 8
```

Then combined delay:

```text
delay_ul_slots = delay_dl_slots = 0, 1, 2, 4, 8
```

Then capacity-limited fake FH:

```text
capacity_mbps = unlimited, 10000, 5000, 2500, 1000, 500, 250
```

For every run, record:

- whether UE sync succeeds
- whether RA succeeds
- steady-state UL throughput
- BLER/HARQ/MCS changes
- fake FH queue delay distribution

## Validation Steps

### Phase 1: Baseline Equivalence

With zero fake FH delay and unlimited fake FH capacity:

1. UE sync succeeds.
2. RA succeeds.
3. UL traffic works.
4. No fake FH drops.
5. Throughput is stable across repeated runs.

If this does not work, do not add delay yet.

### Phase 2: Deterministic Delay

Add fixed UL/DL delay in slots. Verify:

1. Simulated time remains ordered.
2. No wall-clock deadline drops occur.
3. OAI behavior changes only due to configured delay.
4. Throughput and HARQ/BLER/MCS are logged.

### Phase 3: Capacity Model

Add byte-rate-limited queues. Verify:

1. Queue depth increases when offered load exceeds fake capacity.
2. Observed delay tracks queue depth.
3. Throughput degradation correlates with logical FH latency.

### Phase 4: Optional Deadline Mode

Only after the latency experiment works, add optional deadline behavior:

```conf
fakefh.drop_if_later_than_slots = N;
```

This is a separate experiment mode for packet loss/deadline sensitivity.

## Risks

### OAI May Assume Real-Time Slot Progress

Some threads may expect slot callbacks at a fixed cadence or expect data by a specific slot. If so, the fake backend must provide a shared simulated clock and block readers/writers consistently.

### Raw IQ Delay May Break PHY Before CSI Aging Is Visible

If delayed raw IQ simply arrives too late for OAI's processing window, the result may be decode failure rather than graceful scheduler degradation. In that case, we may need to delay specific logical feedback paths rather than all IQ.

### Scheduler May Not Use CSI In The Current Test Mode

If the current setup uses fixed MCS or limited CSI feedback, latency may not change throughput much. We need to confirm which OAI scheduler feedback signals are active.

### Faithfulness Boundary

The fake backend preserves OAI process split and OAI PHY/MAC processing, but not real O-RAN packet format or NIC behavior. This is acceptable for latency/control-loop impairment, but not for compliance or NIC performance claims.

## Initial Implementation Plan

1. Add a `radio/fakefh` backend implementing `device_init`.
2. Reuse the `openair0_device_t` function-pointer pattern from `vrtsim`.
3. Implement a shared-memory or Unix-socket channel for timestamped IQ messages.
4. Add config parsing for role, channel name, delay, capacity, queue limit, and stats period.
5. Implement blocking `trx_read_func` and `trx_write_func`.
6. Implement simulated timestamp progression.
7. Add per-direction counters and periodic stats logs.
8. Add launch scripts for:
   - `run_ru_fakefh.sh`
   - `run_du_fakefh.sh`
   - optionally `run_ue_fakefh.sh`
9. Validate zero-delay sync/RA.
10. Run delay sweeps and collect throughput/BLER/HARQ/MCS stats.

## First Milestone Definition

Milestone 1 is complete when:

- `nr-oru` and `nr-softmodem` run as separate processes.
- They communicate through fake FH, not xRAN/DPDK.
- UE can sync and complete RA at zero fake FH delay.
- UL traffic can be generated.
- fake FH reports radio-time UL throughput and queue metrics.
- There are no app-layer-too-slow packet drops from xRAN.

## Decision

Start with a fake non-realtime logical FH backend, not a fake xRAN backend.

The first implementation should favor clean controllable latency over O-RAN packet fidelity. Once we can measure the latency/control-loop effect, we can decide whether adding more xRAN-like C-plane/U-plane details is worth the complexity.
