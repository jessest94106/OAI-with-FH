#!/usr/bin/env python3
# Plot the FH-load sweep: UL-throughput degradation under real measured FH U-plane loss,
# fine resolution through the saturation knee.
import csv
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

rows=[]
with open("/tmp/sweep_results.csv") as f:
    for r in csv.DictReader(f): rows.append(r)
PRB =[int(r["PRB"]) for r in rows]
mhz =[round(p*12*0.03/0.9) for p in PRB]            # approx channel BW (MHz), 30kHz SCS, ~90% util
loss=[float(r["fh_loss_pct"]) for r in rows]
cal =[float(r["cal_real_Mbps"]) for r in rows]
# trace provenance: P133(108PRB,~25%)/P162(139PRB,~42%) are measured NIC traces;
# all others are structure-preserving synth (measured burst shape, target loss rate)
src=["measured" if p in (108,139) else "synth" for p in PRB]
base=cal[0] if cal and cal[0]>0 else 1.0

print(f"{'PRB':>4} {'~MHz':>5} {'FHload':>7} {'loss%':>6} {'UL_real':>8} {'%base':>6} {'src':>8}")
for i in range(len(rows)):
    print(f"{PRB[i]:>4} {mhz[i]:>5} {rows[i]['FHload_Mbps']:>7} {loss[i]:>6.1f} {cal[i]:>8.2f} {100*cal[i]/base:>5.0f}% {src[i]:>8}")

fig,ax=plt.subplots(1,2,figsize=(12.5,4.8))
# left: UL vs FH loss% (the knee)
ax[0].axhline(base,ls=':',c='gray',alpha=0.6,label=f'lossless baseline {base:.0f} Mbps')
for i in range(len(rows)):
    c='tab:blue' if src[i]=='measured' else 'tab:orange'
    ax[0].scatter(loss[i],cal[i],c=c,s=70,zorder=3)
ax[0].plot(loss,cal,'k--',alpha=0.4,zorder=2)
ax[0].set_xlabel("FH U-plane loss (%)"); ax[0].set_ylabel("Calibrated real UL throughput (Mbps)")
ax[0].set_title("UL collapse vs fronthaul loss (knee-resolved)"); ax[0].grid(alpha=0.3)
ax[0].scatter([],[],c='tab:blue',label='measured NIC trace'); ax[0].scatter([],[],c='tab:orange',label='synth (measured struct)')
ax[0].legend(fontsize=8)
# right: UL vs BW / FH load
ax[1].plot(PRB,cal,'o-',c='tab:red',zorder=3)
ax[1].axvline(80.7,ls=':',c='gray',alpha=0.7); ax[1].text(81,base*0.5,"FH saturates\n(~3.3 Gbps cap)",fontsize=8,color='gray')
for i in range(len(rows)): ax[1].annotate(f"{loss[i]:.0f}%",(PRB[i],cal[i]),textcoords="offset points",xytext=(5,5),fontsize=8)
ax[1].set_xlabel("UL PRBs (4-ant FH load = 40.9 Mbps/PRB)"); ax[1].set_ylabel("Calibrated real UL throughput (Mbps)")
ax[1].set_title("UL throughput vs bandwidth / FH load"); ax[1].grid(alpha=0.3)
plt.tight_layout(); plt.savefig("/tmp/fh_sweep.png",dpi=115)
print("\nsaved /tmp/fh_sweep.png")
