#!/usr/bin/env python3
# Synthesize a high-loss FH drop-trace at a target loss rate the rig cannot COUNT
# (>43% -> dropped pkts fall in untracked seq tails), using REAL measured ingredients:
#   - burst-length distribution: empirical PMF from the measured P162 trace (mean_burst 1.26)
#   - loss rate: from the measured shared-VEB cap (~3.3 Gbps collapsed floor)
# Gaps are geometric (max-entropy given the mean) -> only assumption is the GAP shape,
# the burst CLUSTERING (what the user cares about) is the measured tail-drop structure.
import sys, struct
SRC="/tmp/fhtrace_P162.bin"; OUT=sys.argv[1]; L=float(sys.argv[2]); NLEN=int(sys.argv[3]) if len(sys.argv)>3 else 2_000_000

d=open(SRC,"rb").read()
# empirical burst-length histogram (consecutive 1s)
hist={}; cur=d[0]; ln=1
for x in d[1:]:
    if x==cur: ln+=1
    else:
        if cur: hist[ln]=hist.get(ln,0)+1
        cur=x; ln=1
if cur: hist[ln]=hist.get(ln,0)+1
lens=sorted(hist); cum=[]; tot=sum(hist.values()); c=0
for k in lens: c+=hist[k]; cum.append((k,c/tot))
mean_burst=sum(k*hist[k] for k in lens)/tot
# At high loss the burst run-length MUST grow (you can't reach >56% loss with mean_burst
# 1.26 and minimum gap 1). Physical: severe overload keeps the VEB queue full longer ->
# longer drop runs (the real P217/P273 captures confirmed mean_burst rising to ~1.82).
# Keep the MEASURED gap mean from P162 and SCALE the measured burst SHAPE to the mean
# the target loss requires: loss = MB/(MB+MG) -> MB_target = MG*L/(1-L).
# For L up to ~0.55 the measured burst run-lengths (mean 1.26, min gap 1) can realize the
# target loss directly -> KEEP the measured burst histogram (bscale=1) and set the gap mean
# to hit L. Only for L>0.55 must bursts lengthen (scale the measured shape).
maxL_nochange = mean_burst/(mean_burst+1.0)      # ~0.557
if L <= maxL_nochange:
    bscale = 1.0
    MG = mean_burst*(1.0-L)/L                     # loss = MB/(MB+MG) = L, measured bursts
    MB_target = mean_burst
else:
    MG = mean_burst*(1-0.422)/0.422              # P162 measured gap mean
    MB_target = MG*L/(1.0-L)
    bscale = MB_target/mean_burst
# deterministic LCG (no Math.random equivalent needed; reproducible)
state=0x2545F4914F6CDD1D
def u01():
    global state
    state=(state*6364136223846793005+1442695040888963407)&0xFFFFFFFFFFFFFFFF
    return (state>>11)/(1<<53)
def samp_burst():
    r=u01()
    for k,cp in cum:
        if r<=cp: return max(1,round(k*bscale))   # measured shape, scaled to physical mean
    return max(1,round(lens[-1]*bscale))
def samp_gap():
    # geometric with mean MG (measured P162 gap mean): P(g)=(1-p)^(g-1) p, gap>=1
    import math
    p=1.0/max(1.0,MG)
    g=1+int(math.log(max(1e-12,u01()))/math.log(1-p)) if p<1 else 1
    return max(1,g)
out=bytearray()
while len(out)<NLEN:
    out+=b'\x01'*samp_burst()
    out+=b'\x00'*samp_gap()
out=out[:NLEN]
open(OUT,"wb").write(out)
got=sum(out)/len(out)
print(f"{OUT}: target_loss={L:.0%} got={got:.1%} mean_burst src={mean_burst:.2f}->target={MB_target:.2f} (scale {bscale:.2f}) mean_gap={MG:.2f} len={len(out)}")
