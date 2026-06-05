#!/usr/bin/env python3
# BW sweep with the regular-thinning FH time-pattern model: UL throughput vs BW,
# with FH load and FH loss (incl. the congestion-collapse jump).
import csv
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

rows=[]
with open("/tmp/thinning_results.csv") as f:
    for r in csv.DictReader(f): rows.append(r)
PRB =[int(r["PRB"]) for r in rows]
mhz =[int(r["BW_MHz"]) for r in rows]
load=[float(r["FH_load_Mbps"]) for r in rows]
loss=[float(r["FH_loss_pct"]) for r in rows]
ul  =[float(r["UL_real_Mbps"]) for r in rows]

print(f"{'PRB':>4} {'BW_MHz':>6} {'FH_load':>8} {'FH_loss':>8} {'UL_real':>8}")
for i in range(len(rows)):
    print(f"{PRB[i]:>4} {mhz[i]:>6} {load[i]:>8.0f} {loss[i]:>7.1f}% {ul[i]:>8.2f}")

fig,ax=plt.subplots(1,2,figsize=(13,4.8))
# left: UL vs BW, annotate FH loss; mark collapse
ax[0].plot(mhz,ul,'o-',color='tab:red',zorder=3)
for i in range(len(rows)):
    ax[0].annotate(f"{loss[i]:.0f}%",(mhz[i],ul[i]),textcoords="offset points",xytext=(5,6),fontsize=8)
ax[0].axvspan(52,56,color='gray',alpha=0.15)
ax[0].text(54,max(ul)*0.55,"congestion\ncollapse",fontsize=8,ha='center',color='dimgray')
ax[0].set_xlabel("Channel bandwidth (MHz)"); ax[0].set_ylabel("UL throughput (Mbps, real/calibrated)")
ax[0].set_title("UL vs BW under measured FH time-pattern loss\n(labels = FH loss %)"); ax[0].grid(alpha=0.3)
# right: FH load + FH loss vs BW (twin axis)
axb=ax[1]; axb2=axb.twinx()
axb.plot(mhz,[l/1000 for l in load],'s-',color='tab:blue',label='FH load (Gbps)')
axb.axhline(3.3,ls=':',color='navy',alpha=0.7); axb.text(22,3.4,"VEB cap ~3.3 Gbps",fontsize=8,color='navy')
axb2.plot(mhz,loss,'^-',color='tab:red',label='FH loss (%)')
axb.set_xlabel("Channel bandwidth (MHz)"); axb.set_ylabel("FH offered load (Gbps)",color='tab:blue')
axb2.set_ylabel("FH U-plane loss (%)",color='tab:red')
axb.set_title("FH load & loss vs BW (4-ant, iq16, 40.9 Mbps/PRB)"); axb.grid(alpha=0.3)
plt.tight_layout(); plt.savefig("/tmp/fh_thinning_sweep.png",dpi=115)
print("\nsaved /tmp/fh_thinning_sweep.png")
