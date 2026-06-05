#!/usr/bin/env python3
# Realistic two-host full-duplex FH switch model vs the VF/VEB loopback artifact.
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from fh_switch_model import simulate

PRBS=list(range(51,301,8))
mhz=[round(p*12*0.03/0.9) for p in PRBS]

fig,ax=plt.subplots(1,2,figsize=(13,4.8))
# A) loss vs BW: realistic switch (3 configs) vs VEB collapse
for C,B,c,lab in [(10,128,'tab:red','10G FH, 128KB buf (105us)'),
                  (10,256,'tab:orange','10G FH, 256KB buf (210us)'),
                  (25,128,'tab:green','25G FH, 128KB buf')]:
    loss=[100*simulate(p,C_gbps=C,buf_kb=B)[0] for p in PRBS]
    ax[0].plot(mhz,loss,'o-',color=c,ms=3,label=lab)
# VEB (half-duplex loopback): aggregate 40.9 Mbps/PRB vs cap+collapse
veb=[]
for p in PRBS:
    L=40.9*p
    l=(L-4500)/L if L<=5400 else (L-3300)/L
    veb.append(100*max(0,l))
ax[0].plot(mhz,veb,'s--',color='gray',ms=3,label='VF/VEB loopback (artifact)')
ax[0].set_xlabel("Channel BW (MHz)  [4-ant UL, iq16]"); ax[0].set_ylabel("FH U-plane loss (%)")
ax[0].set_title("Realistic full-duplex FH vs VEB loopback\n(real FH: lossless until per-symbol burst > line rate)")
ax[0].grid(alpha=0.3); ax[0].legend(fontsize=8)

# B) realistic time pattern: loss vs position within the TDD period (273 PRB, 10G/128KB)
loss,tr,avg,peak=simulate(273,C_gbps=10,buf_kb=128,n_periods=600)
PKT_PER_PERIOD=2*14*4   # ul_slots*sym*ant = 112
import numpy as np
a=np.frombuffer(tr,dtype=np.uint8)
nper=len(a)//PKT_PER_PERIOD
m=a[:nper*PKT_PER_PERIOD].reshape(nper,PKT_PER_PERIOD).mean(0)*100
ax[1].plot(range(PKT_PER_PERIOD),m,color='tab:red',lw=1)
ax[1].fill_between(range(PKT_PER_PERIOD),m,alpha=0.25,color='tab:red')
ax[1].set_xlabel("packet index within UL burst-train (2 UL slots x 14 sym x 4 ant)")
ax[1].set_ylabel("drop probability (%)")
ax[1].set_title(f"Realistic FH loss TIME-pattern (273 PRB, 10G/128KB)\nbuffer fills during the UL burst -> drops at the tail")
ax[1].grid(alpha=0.3)
plt.tight_layout(); plt.savefig("/tmp/fh_realistic.png",dpi=115)
print("saved /tmp/fh_realistic.png  (overall loss=%.1f%% avg=%.1fG peak=%.1fG)"%(100*loss,avg,peak))
