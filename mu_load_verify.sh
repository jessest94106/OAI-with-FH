#!/bin/bash
# Full MU-MIMO verification UNDER LOAD: server-less UDP saturation on both UEs -> co-scheduling ->
# joint detector under real co-channel traffic. Args: $1=NB_ANT_RX (default 4).
cd /home/jesse/oran_lab
NRX="${1:-4}"
best=""
for t in $(seq 1 6); do
  N_UE=2 NB_ANT_RX=$NRX TS=0.25 IPERF_SECONDS=40 ATTACH_WAIT=90 UL_RATE_MBPS=60 \
    OAI_UL_MU_SCID=1 VRTSIM_UL_MU_STEER=auto OAI_UL_MU_COSCHED=1 OAI_UL_MU_IRC=1 \
    bash run_multi_ue.sh >/tmp/mu_load_try$t.full 2>&1
  D=$(ls -td /home/jesse/oran_lab/logs/multiue_* | head -1)
  u0=0; u1=0
  grep -qaE 'TUN Interface .*successfully configured|PDU Session Establishment Accept' "$D/ue0.log" 2>/dev/null && u0=1
  grep -qaE 'TUN Interface .*successfully configured|PDU Session Establishment Accept' "$D/ue1.log" 2>/dev/null && u1=1
  nrnti=$(grep -aoE "UE [0-9a-f]{4}" "$D/du.log" 2>/dev/null | sort -u | wc -l)
  irc=$(grep -acE "\[MU METRIC\]" "$D/du.log" 2>/dev/null)
  echo "try$t(${NRX}RX): UE0=$u0 UE1=$u1 du_crnti=$nrnti irc_metric=$irc dir=$(basename $D)"
  if [ "$u0" = 1 ] && [ "$u1" = 1 ] && [ "$irc" -gt 3 ]; then best="$D"; echo "  >>> 2/2 + IRC firing under load <<<"; break; fi
done
if [ -n "$best" ]; then
  echo "=== ul_saturate output (both UEs sending?) ==="; for f in "$best"/ul_ue*.log; do echo "$(basename $f): $(tail -1 $f)"; done
  echo "=== SEPARATION HEALTH under load (last 10 [MU METRIC]) ==="; grep -aoE "\[MU METRIC\].*" "$best/du.log" | tail -10
  echo "=== SAME-SLOT co-scheduling (both UEs one frame.slot) ==="
  grep -aoE "ULSCH (ACK|NAK) trace [0-9]+\.[0-9]+ rnti [0-9a-f]{4}" "$best/du.log" | awk '{print $4,$6}' | sort | \
    awk '{s[$1]=s[$1]" "$2} END{c=0; for(k in s){n=split(s[k],a," "); d=0; for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(a[i]!=a[j])d=1; if(d)c++} print "TOTAL same-slot co-sched slots: "c}'
  echo "=== per-rnti crc_valid on rb 0+273 ==="; grep -aoE "rnti [0-9a-f]{4} .*crc_valid [01].*rb 0\+273" "$best/du.log" | grep -oE "rnti [0-9a-f]{4}|crc_valid [01]" | paste - - | sort | uniq -c
  echo "=== per-UE gNB LCID4 goodput (final MAC) ==="; grep -aE "LCID 4:" /home/jesse/oran_lab/oaicicd/test_dir/openairinterface5g/build/nrMAC_stats.log 2>/dev/null | tail -4
fi
