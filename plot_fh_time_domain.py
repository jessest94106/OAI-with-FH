#!/usr/bin/env python3
# TIME-DOMAIN FH loss model under overload. Three views:
#  A) windowed loss-rate time series: sustained-overload (steady) vs near-knee (intermittent)
#  B) inter-drop interval distribution + CV: regular(sub-Poisson) / Poisson / bursty?
#  C) autocorrelation of the drop indicator: memory structure (clustered vs anti-correlated)
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

def load(path): return np.frombuffer(open(path,"rb").read(),dtype=np.uint8).astype(np.float64)

OVL="/tmp/fhtrace_R6300.bin"   # 42% sustained overload (stationary)
KNEE="/tmp/fhtrace_R4800.bin"  # ~6% near saturation knee (intermittent)

# packet -> time: NIC ~1400B at ~3.3 Gbps fabric => ~3.4 us/packet
US_PER_PKT = 1400*8/3.3e9*1e6

dov=load(OVL); dkn=load(KNEE)
fig,ax=plt.subplots(1,3,figsize=(16,4.6))

# A) windowed loss-rate time series
W=2000
def wseries(d):
    n=(len(d)//W)*W; m=d[:n].reshape(-1,W).mean(1)*100
    t=np.arange(len(m))*W*US_PER_PKT/1000.0  # ms
    return t,m
t1,m1=wseries(dov); t2,m2=wseries(dkn)
ax[0].plot(t1[:300],m1[:300],color='tab:red',lw=0.9,label=f'overload (42%): steady')
ax[0].plot(t2[:300],m2[:300],color='tab:green',lw=0.9,label=f'near-knee (~6%): intermittent')
ax[0].set_xlabel("time (ms, @~3.4 us/pkt)"); ax[0].set_ylabel("loss in 2000-pkt window (%)")
ax[0].set_title("A) loss-rate over time"); ax[0].grid(alpha=0.3); ax[0].legend(fontsize=8)

# B) inter-drop interval (gap between consecutive dropped packets) distribution
def gaps(d):
    idx=np.flatnonzero(d>0); return np.diff(idx)
g=gaps(dov); cv=g.std()/g.mean()
maxg=12
vals,counts=np.unique(np.clip(g,1,maxg),return_counts=True)
ax[1].bar(vals-0.18,counts/counts.sum(),width=0.36,color='tab:red',label=f'measured (CV={cv:.2f})')
# Poisson/i.i.d. reference: geometric gaps with same mean
mu=g.mean(); pgeo=1.0/mu
kk=np.arange(1,maxg+1); geo=(1-pgeo)**(kk-1)*pgeo; geo=geo/geo.sum()
ax[1].plot(kk,geo,'ks--',ms=4,label='i.i.d. Poisson (CV=1)')
ax[1].axvline(mu,color='blue',ls=':',label=f'mean gap={mu:.2f} pkts (~{mu*US_PER_PKT:.0f} us)')
ax[1].set_xlabel("inter-drop interval (packets between drops)"); ax[1].set_ylabel("probability")
ax[1].set_title("B) drop spacing @42% overload"); ax[1].grid(alpha=0.3); ax[1].legend(fontsize=8)

# C) autocorrelation of the centered drop indicator
def autocorr(d,L=30):
    x=d-d.mean(); v=np.dot(x,x)
    return np.array([np.dot(x[:-k],x[k:])/v for k in range(1,L+1)])
acf=autocorr(dov)
ax[2].axhline(0,color='k',lw=0.6); ax[2].bar(range(1,31),acf,color='tab:red')
ax[2].set_xlabel("lag (packets)"); ax[2].set_ylabel("autocorrelation of drop indicator")
ax[2].set_title("C) memory @42% (neg lag-1 = anti-clustered)"); ax[2].grid(alpha=0.3)
plt.tight_layout(); plt.savefig("/tmp/fh_time_domain.png",dpi=115)
print("saved /tmp/fh_time_domain.png")

# numeric summary
for name,d in [("overload 42% (R6300)",dov),("near-knee 6% (R4800)",dkn)]:
    g=gaps(d); cv=g.std()/g.mean()
    W=2000; n=(len(d)//W)*W; wl=d[:n].reshape(-1,W).mean(1)*100
    a1=autocorr(d,1)[0]
    print(f"{name}: loss={100*d.mean():.1f}%  mean_gap={g.mean():.2f} pkts (~{g.mean()*US_PER_PKT:.0f} us)  "
          f"gap_CV={cv:.2f}  lag1_autocorr={a1:+.3f}  window_loss_std={wl.std():.1f}%")
