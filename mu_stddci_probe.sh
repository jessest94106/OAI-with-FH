#!/bin/bash
# STANDARD-5G path test: gNB assigns ports -> DCI 0_1 antenna_ports carries them -> UE follows.
# NO env forces (MU_UE_FORCE unset). [DCI TX]/[DCI RX] instrument every hop.
cd /home/jesse/oran_lab; MAC=oaicicd/test_dir/openairinterface5g/build/nrMAC_stats.log
for t in $(seq 1 8); do
  N_UE=2 NB_ANT_RX=2 TS=0.25 IPERF_SECONDS=60 ATTACH_WAIT=110 UL_RATE_MBPS=80 \
    VRTSIM_UL_MU_STEER=auto VRTSIM_UL_MU_STEER_BOOT=1 \
    OAI_UL_MU_PORTS=1 OAI_UL_MU_COSCHED=1 OAI_UL_MU_IRC=1 \
    bash run_multi_ue.sh >/tmp/mu_std_try$t.full 2>&1
  D=$(ls -td logs/multiue_* | head -1)
  u0=0;u1=0
  grep -qaE 'PDU Session|TUN.*configured' "$D/ue0.log" 2>/dev/null && u0=1
  grep -qaE 'PDU Session|TUN.*configured' "$D/ue1.log" 2>/dev/null && u1=1
  echo "try$t: UE0=$u0 UE1=$u1"
  if [ "$u0" = 1 ] && [ "$u1" = 1 ]; then
    echo "  >>> 2/2 (STANDARD DCI) <<<"
    echo "-- gNB [DCI TX] (what it encodes) --"; grep -aoE "\[DCI TX\].*" "$D/du.log" | sort -u | head -6
    echo "-- UE0 [DCI RX] --"; grep -aoE "\[DCI RX\].*" "$D/ue0.log" | sort -u | head -4
    echo "-- UE1 [DCI RX] (port1 received?) --"; grep -aoE "\[DCI RX\].*" "$D/ue1.log" | sort -u | head -4
    echo "-- UE1 [UE DMRS TX] (actually transmits port1/scid?) --"; grep -aoE "\[UE DMRS TX\].*" "$D/ue1.log" | tail -3
    echo "-- corr + postSINR + phantom fails --"; grep -aoE "corr2pct=[0-9-]+ .*postSINR=[0-9.-]+dB" "$D/du.log" | tail -5
    echo "-- per-UE mcs --"; grep -aoE "rnti [0-9a-f]{4} .*mcs [0-9]+ Qm" "$D/du.log" | grep -oE "rnti [0-9a-f]{4}|mcs [0-9]+" | paste - - | sort | uniq -c | tail -6
    echo "-- per-UE LCID4 --"; grep -aE "UE [0-9a-f]{4}:" "$MAC" | grep -aE "LCID 4:" | tail -4
    break
  fi
done
