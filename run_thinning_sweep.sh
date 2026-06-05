#!/bin/bash
# BW sweep with the MEASURED TIME-PATTERN loss model (regular thinning) inserted at RU->DU,
# driven by the per-BW loss rate (no trace replay). Reports FH load, FH loss, BW, UL.
# loss(load): two-segment from the measured shared-VEB cap + congestion collapse:
#   load<=5400 Mbps  -> pre-collapse cap ~4500: loss = max(0,(load-4500)/load)
#   load >5400 Mbps  -> collapsed cap  3300: loss = (load-3300)/load   (the collapse jump)
# FH load = 40.9 Mbps/PRB (4-antenna aggregate U-plane, uncompressed iq16).
BASE=/home/jesse/oran_lab; CONF=$BASE/gnb_clean_106_4rx.conf
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/th_gnb.log; U=/tmp/th_ue.log
# PRB list -> load and loss computed below
PRBS=(51 80 106 120 130 140 162 217 273)
echo 0 > /tmp/fh_inject_loss; echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_us
echo 1 > /tmp/fh_model            # SELECT regular-thinning time-pattern model
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
cleanup(){ sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; echo 0 > /tmp/fh_model; }
trap cleanup EXIT
rxb(){ sudo nsenter -t $UPF_PID -n ip -s link show tun0 | awk '/RX:/{getline; print $1; exit}'; }
attach(){
  UE_IP=""
  for try in $(seq 1 14); do
    sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2; : > $G; : > $U
    sudo -E taskset -c 4-15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-softmodem" -O $CONF --rfsim >$G 2>&1 &
    ok=0; for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" $G && { ok=1; break; }; done; [[ $ok = 1 ]] || continue
    sleep 2
    sudo taskset -c 16-27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-uesoftmodem" -O $BASE/nrue_clean.conf --rfsim -C 3319680000 -r 106 --numerology 1 >$U 2>&1 &
    sib=0; for i in $(seq 1 18); do sleep 1; grep -qE "SIB1 decoded|Found SIB1" $U && { sib=1; break; }; done; [[ $sib = 1 ]] || continue
    for i in $(seq 1 40); do sleep 1; UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null|awk '{print $4}'|cut -d/ -f1|head -1); [[ -n "$UE_IP" ]] && break; done
    [[ -z "$UE_IP" ]] && continue
    pr=$(ping -I "$UE_IP" -c 5 -W 2 10.0.0.1 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+')
    echo "  try $try: UE_IP=$UE_IP UL-ping=${pr:-0}/5"; [[ "${pr:-0}" -ge 2 ]] && return 0; UE_IP=""
  done
  return 1
}
measure(){  # $1=loss_fraction -> meas R measured_loss
  echo "$1" > /tmp/fh_inject_loss; sleep 4
  ping -I "$UE_IP" -c 2 -W 2 10.0.0.1 >/dev/null 2>&1
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
  sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/th_srv.log -D; sleep 1
  local b0 b1 n0 t0 t1 n1; b0=$(rxb); n0=$(grep -c "stats sfn" $U); t0=$(date +%s.%N)
  timeout 32 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 50M -t 22 >/dev/null 2>&1
  t1=$(date +%s.%N); b1=$(rxb); n1=$(grep -c "stats sfn" $U)
  R=$(awk "BEGIN{print ($t1-$t0>0)?($n1-$n0)*1.28/($t1-$t0):0}")
  meas=$(awk "BEGIN{w=$t1-$t0; print (w>0 && \"$b1\"!=\"\" && \"$b0\"!=\"\")?($b1-$b0)*8/1e6/w:0}")
  mloss=$(grep -oE "mode=thinning dropped [0-9]+/[0-9]+ pkts \([0-9.]+%\)" $G | tail -6 | grep -oE "\([0-9.]+%\)" | tr -d '()%' | awk '{s+=$1;n++}END{print (n>0)?s/n:0}')
  [[ "$1" = "0" || "$1" = "0.000" ]] && mloss=0
}
echo "[thinning-sweep] attaching..."; attach || { echo "ATTACH FAILED"; exit 1; }
echo "[thinning-sweep] GOOD ATTACH UE_IP=$UE_IP (model=regular-thinning)"
printf "\n%-4s %-6s %-10s %-9s %-9s %-7s %-9s\n" "PRB" "BW_MHz" "FHload_Mb" "FHloss%" "measLoss%" "R" "UL_real"
RES=/tmp/thinning_results.csv; echo "PRB,BW_MHz,FH_load_Mbps,FH_loss_pct,meas_loss_pct,clock_R,UL_real_Mbps" > $RES
for PRB in "${PRBS[@]}"; do
  load=$(awk "BEGIN{printf \"%.0f\", 40.9*$PRB}")
  mhz=$(awk "BEGIN{printf \"%.0f\", $PRB*12*0.03/0.9}")
  loss=$(awk "BEGIN{L=40.9*$PRB; if(L<=5400){l=(L-4500)/L; if(l<0)l=0}else{l=(L-3300)/L}; printf \"%.4f\", l}")
  cur=$(ip -4 -o addr show oaitun_ue1 2>/dev/null|awk '{print $4}'|cut -d/ -f1|head -1)
  [[ -z "$cur" ]] && { echo "  [reattach before PRB=$PRB]"; attach || { echo skip; continue; }; }
  measure "$loss"
  cal=$(awk "BEGIN{print ($R>0)?$meas/$R:$meas}")
  lp=$(awk "BEGIN{printf \"%.1f\", $loss*100}")
  printf "%-4s %-6s %-10s %-9s %-9s %-7s %-9s\n" "$PRB" "$mhz" "$load" "$lp" "$(printf %.1f ${mloss:-0})" "$(printf %.2f $R)" "$(printf %.2f $cal)"
  echo "$PRB,$mhz,$load,$lp,$mloss,$R,$cal" >> $RES
done
echo; echo "[thinning-sweep] done -> $RES"
