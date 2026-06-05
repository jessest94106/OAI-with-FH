#!/usr/bin/env python3
# Realistic two-host O-RAN 7.2 fronthaul loss model: a FULL-DUPLEX switch egress queue
# (line rate C, latency-bounded buffer B, tail-drop) fed by the real periodic UL U-plane
# traffic. UL and DL are separate directions (full-duplex) -> the UL link carries UL only.
# Loss EMERGES from per-symbol bursts vs the buffer; there is NO congestion collapse
# (that was the VF<->VF half-duplex VEB-loopback artifact). The drop time-pattern is the
# switch's real tail-drop (bursty within an overflowing UL burst-train, drains in the gaps).
#
# Arrivals: per UL symbol, n_ant packets of (prb*12*4*comp) bytes arrive together (the
# symbol burst), at the symbol time; queue drains at C continuously (incl. the DL/idle gaps).
import sys

def simulate(prb, n_ant=4, C_gbps=10.0, buf_kb=128, comp=1.0,
             mu=1, ul_slots=2, period_slots=10, n_periods=600):
    sym_per_slot = 14
    slot_s   = 1e-3 / (2**mu)                 # mu=1 -> 0.5 ms
    T_sym    = slot_s / sym_per_slot          # mu=1 -> 35.7 us
    period_s = period_slots * slot_s
    C        = C_gbps * 1e9 / 8.0             # bytes/s drained
    B        = buf_kb * 1024.0                # buffer bytes
    S        = prb * 12 * 4 * comp            # bytes per (antenna,symbol) U-plane packet
    # UL slots placed at the END of the period (e.g. 7D/1S/2U -> slots 8,9)
    ul_slot_idx = list(range(period_slots - ul_slots, period_slots))
    Q = 0.0; last_t = 0.0
    trace = bytearray()
    drops = 0; tot = 0
    for p in range(n_periods):
        for sl in ul_slot_idx:
            for sym in range(sym_per_slot):
                t = p*period_s + sl*slot_s + sym*T_sym
                Q = max(0.0, Q - C*(t - last_t))   # drain since last packet (incl. idle gaps)
                last_t = t
                for a in range(n_ant):
                    tot += 1
                    if Q + S <= B:
                        Q += S; trace.append(0)
                    else:
                        drops += 1; trace.append(1)
    loss = drops/tot if tot else 0.0
    avg_load = n_ant*prb*12*4*comp * (ul_slots*sym_per_slot/period_s) * 8 / 1e9   # Gbps
    peak_load= n_ant*S/T_sym * 8 / 1e9                                            # Gbps (in-burst)
    return loss, bytes(trace), avg_load, peak_load

def burststats(tr):
    import statistics
    b=[];cur=tr[0];ln=1
    for x in tr[1:]:
        if x==cur:ln+=1
        else:
            if cur:b.append(ln)
            cur=x;ln=1
    if cur:b.append(ln)
    if not b: return 0,0
    return statistics.mean(b), sum(1 for x in b if x==1)/len(b)

if __name__=="__main__":
    PRBS=[51,106,133,162,217,273]
    print("=== Realistic full-duplex FH switch model (4-ant UL, iq16, 7D/1S/2U) ===")
    for C,B in [(10,128),(10,256),(25,128)]:
        print(f"\n-- line rate {C} Gbps, buffer {B} KB (~{B*1024*8/(C*1e9)*1e6:.0f} us of buffering) --")
        print(f"   {'PRB':>4} {'~MHz':>5} {'avgLd':>6} {'peakLd':>7} {'loss%':>6}  burst(mean/singleton)")
        for prb in PRBS:
            loss,tr,avg,peak=simulate(prb,C_gbps=C,buf_kb=B)
            mb,sg=burststats(tr)
            mhz=round(prb*12*0.03/0.9)
            print(f"   {prb:>4} {mhz:>5} {avg:>5.1f}G {peak:>6.1f}G {100*loss:>5.1f}%  {mb:.2f}/{sg:.2f}")
