#!/usr/bin/env python3
# REAL NIC measurements only (no model). VF<->VF VEB captures: loss + burst structure
# vs offered load. Clean tail-drop regime (<=~5.2G) = real full-duplex-like behaviour;
# beyond ~5.5G is the VF/VEB half-duplex COLLAPSE artifact (discard for FH purposes).
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

# measured points: offered_Gbps, loss%, mean_burst  (from nic_capture_fine.sh + nic_capture_batch.sh)
off  =[3.80,4.00,4.20,4.34,4.50,4.80,5.20,5.44,5.70,6.30,6.62,7.00]
loss =[3.5 ,1.2 ,3.5 ,0.0 ,4.3 ,6.2 ,10.3,24.9,41.4,42.1,42.6,41.3]
mb   =[1.26,1.13,1.15,1.14,1.35,1.37,1.17,1.26,1.20,1.23,1.23,1.20]
clean=[o<=5.25 for o in off]

fig,ax=plt.subplots(1,2,figsize=(12.5,4.7))
# A) measured loss vs offered load
for i in range(len(off)):
    c='tab:green' if clean[i] else 'tab:gray'
    ax[0].scatter(off[i],loss[i],c=c,s=60,zorder=3)
ax[0].axvspan(3.3,5.25,color='tab:green',alpha=0.08); ax[0].axvspan(5.25,7.2,color='tab:gray',alpha=0.12)
ax[0].text(4.2,33,"REAL clean tail-drop\n(full-duplex-like)",color='green',fontsize=9,ha='center')
ax[0].text(6.1,20,"VEB half-duplex\nCOLLAPSE (artifact)",color='dimgray',fontsize=9,ha='center')
ax[0].set_xlabel("offered FH load (Gbps)   [BW = load / 40.9 Mbps-per-PRB]")
ax[0].set_ylabel("MEASURED FH U-plane loss (%)")
ax[0].set_title("Real NIC measurement: loss vs offered load"); ax[0].grid(alpha=0.3)
# BW secondary axis
ax2=ax[0].twiny(); ax2.set_xlim(ax[0].get_xlim())
ticks=[3.3,4.5,5.7,7.0]; ax2.set_xticks(ticks); ax2.set_xticklabels([f"{int(t*1000/40.9)}" for t in ticks])
ax2.set_xlabel("equivalent PRB (4-ant, iq16)")
# B) measured burst structure (the real loss process) vs load
for i in range(len(off)):
    c='tab:green' if clean[i] else 'tab:gray'
    ax[1].scatter(off[i],mb[i],c=c,s=60,zorder=3)
ax[1].axhline(1.0,ls=':',c='k',alpha=0.5)
ax[1].set_xlabel("offered FH load (Gbps)"); ax[1].set_ylabel("measured mean drop-burst length")
ax[1].set_title("Real loss PROCESS: singleton-dominated tail-drop\n(mean burst ~1.2 -> transfers to any switch)")
ax[1].grid(alpha=0.3); ax[1].set_ylim(0.9,1.6)
plt.tight_layout(); plt.savefig("/tmp/fh_real_only.png",dpi=115)
print("saved /tmp/fh_real_only.png")
