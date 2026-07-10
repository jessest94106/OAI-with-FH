#!/bin/bash
# STAGE-2: FD-OCC DMRS ports (real pilots), NO genie, NO scid. The real MU-MIMO test.
cd /home/jesse/oran_lab; MAC=oaicicd/test_dir/openairinterface5g/build/nrMAC_stats.log
for t in $(seq 1 8); do
  N_UE=2 NB_ANT_RX=2 TS=0.25 IPERF_SECONDS=60 ATTACH_WAIT=110 UL_RATE_MBPS=80 \
    VRTSIM_UL_MU_STEER=auto VRTSIM_UL_MU_STEER_BOOT=1 \
    OAI_UL_MU_PORTS=1 OAI_UL_MU_COSCHED=1 OAI_UL_MU_IRC=1 \
    bash run_multi_ue.sh >/tmp/mu_ports_try$t.full 2>&1
  D=$(ls -td logs/multiue_* | head -1)
  u0=0;u1=0
  grep -qaE 'PDU Session|TUN.*configured' "$D/ue0.log" 2>/dev/null && u0=1
  grep -qaE 'PDU Session|TUN.*configured' "$D/ue1.log" 2>/dev/null && u1=1
  echo "try$t: UE0=$u0 UE1=$u1"
  if [ "$u0" = 1 ] && [ "$u1" = 1 ]; then
    echo "  >>> 2/2 (PORTS) <<<"
    echo "-- gNB [MU PORT] --"; grep -aoE "\[MU PORT\].*" "$D/du.log" | sort -u | head -4
    echo "-- UE1 [UE FORCE PORT] --"; grep -aoE "\[UE FORCE PORT\].*" "$D/ue1.log" | sort -u | head -2
    echo "-- corr2pct (REAL estimates now; want ~0) + postSINR --"; grep -aoE "corr2pct=[0-9-]+ .*postSINR=[0-9.-]+dB" "$D/du.log" | tail -5
    echo "-- REUSE --"; grep -aoE "real-reuse-slots\(>=2UE/slot\)=[0-9]+" "$D/du.log" | tail -1
    echo "-- per-UE mcs+SNR --"; grep -aoE "rnti [0-9a-f]{4} .*mcs [0-9]+ Qm [0-9]+ SNR [0-9.-]+ dB" "$D/du.log" | grep -oE "rnti [0-9a-f]{4}|mcs [0-9]+" | paste - - | sort | uniq -c | tail -6
    echo "-- per-UE LCID4 (AGGREGATE) --"; grep -aE "UE [0-9a-f]{4}:" "$MAC" | grep -aE "LCID 4:" | tail -4
    break
  fi
done
