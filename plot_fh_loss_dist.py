#!/usr/bin/env python3
# Characterize the MEASURED fronthaul loss DISTRIBUTION (the real VEB tail-drop process):
#  A) drop-burst-length PMF vs the i.i.d.-Bernoulli geometric (shows it is sub-Bernoulli)
#  B) loss% and achieved throughput vs offered load (the shared-fabric cap + collapse)
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

def burst_pmf(path):
    d=open(path,"rb").read(); n=len(d); tot=sum(d)
    hist={}; cur=d[0]; ln=1
    for x in d[1:]:
        if x==cur: ln+=1
        else:
            if cur: hist[ln]=hist.get(ln,0)+1
            cur=x; ln=1
    if cur: hist[ln]=hist.get(ln,0)+1
    nb=sum(hist.values())
    p=tot/n
    return p, {k:hist[k]/nb for k in hist}, sum(k*hist[k] for k in hist)/nb

traces=[("/tmp/fhtrace_R5200.bin","10% (real capture)","tab:green"),
        ("/tmp/fhtrace_P133.bin","25% (real capture)","tab:blue"),
        ("/tmp/fhtrace_R6300.bin","42% (real capture)","tab:red")]

fig,ax=plt.subplots(1,2,figsize=(12.5,4.8))
# A) burst-length PMF (measured) with Bernoulli geometric overlay (same loss rate)
import math
for path,lab,c in traces:
    p,pmf,mb=burst_pmf(path)
    ks=sorted(pmf);
    ax[0].plot(ks,[pmf[k] for k in ks],'o-',color=c,label=f"{lab}  mean_burst={mb:.2f}")
    # i.i.d. Bernoulli(p) drop-run-length PMF: P(L=k)=(1-p) p^(k-1), mean=1/(1-p)
    kk=list(range(1,max(ks)+1))
    ax[0].plot(kk,[(1-p)*p**(k-1) for k in kk],'--',color=c,alpha=0.5)
ax[0].plot([],[],'k-',label='measured'); ax[0].plot([],[],'k--',alpha=0.5,label='i.i.d. Bernoulli (same loss)')
ax[0].set_yscale('log'); ax[0].set_xlabel("drop-burst length (consecutive lost FH packets)")
ax[0].set_ylabel("probability"); ax[0].set_title("FH loss burst-length distribution\n(measured is SUB-Bernoulli: shorter runs than i.i.d.)")
ax[0].grid(alpha=0.3,which='both'); ax[0].legend(fontsize=8); ax[0].set_xlim(0.5,8)
# B) loss% + achieved vs offered load (the shared half-duplex VEB cap + congestion collapse)
off =[3800,4000,4200,4500,4800,5200,5700,6300,7000]
loss=[3.5,1.2,3.5,4.3,6.2,10.3,41.4,42.1,41.3]
ach =[3.69,3.97,4.07,4.34,4.53,4.60,3.34,3.31,3.35]
axb=ax[1]; axb2=axb.twinx()
axb.plot([o/1000 for o in off],loss,'s-',color='tab:red',label='loss %')
axb2.plot([o/1000 for o in off],ach,'^-',color='tab:gray',label='achieved Gbps')
axb.axhline(0,color='k',lw=0.5)
axb.set_xlabel("offered FH load (Gbps)"); axb.set_ylabel("packet loss (%)",color='tab:red')
axb2.set_ylabel("achieved throughput (Gbps)",color='tab:gray')
axb.set_title("Shared half-duplex VEB: cap ~3.3-4.6 Gbps + congestion collapse")
axb.grid(alpha=0.3); axb.tick_params(axis='y',colors='tab:red')
axb.annotate("collapse:\n4.6->3.3 Gbps\nloss 10->41%",(5.45,25),fontsize=8,color='darkred',ha='center')
plt.tight_layout(); plt.savefig("/tmp/fh_loss_dist.png",dpi=115)
print("saved /tmp/fh_loss_dist.png")
for path,lab,c in traces:
    p,pmf,mb=burst_pmf(path)
    bern=1/(1-p)
    print(f"{lab}: loss={100*p:.1f}%  measured mean_burst={mb:.2f}  Bernoulli mean_burst={bern:.2f}  singletons={pmf.get(1,0)*100:.0f}%")
