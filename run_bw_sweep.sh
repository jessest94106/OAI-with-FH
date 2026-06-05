#!/bin/bash
# FH-load (BW) sweep -> UL-throughput degradation under REAL measured FH U-plane loss.
# gNB nb_rx=4 (UL RX diversity). FH load = 40.9 Mbps/PRB (4-antenna aggregate U-plane) vs
# the measured shared half-duplex VEB cap ~3.3 Gbps -> loss(PRB). Fine resolution through
# the saturation knee (80-108 PRB). Loss injected as a measured/structure-preserving trace
# on the RU->DU rxdataF path. Robust attach GATED BY UL-PING. UL measured via iperf3 UDP
# -b50M reading the SERVER's LIVE per-interval delivered rate (robust to control teardown).
# Calibrated real = wall/R (R from UE 'stats sfn', 128 frames = 1.28 sim-s).
BASE=/home/jesse/oran_lab; CONF=${SWEEP_CONF:-$BASE/gnb_clean_106_4rx.conf}
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/sw_gnb.log; U=/tmp/sw_ue.log
# PRB:FHload_Mbps:trace   (PRB = 3300/(40.9*(1-loss)); load = 40.9*PRB)
POINTS=( "80:3272:off" "81:3317:/tmp/fhtrace_L005.bin" "81:3333:/tmp/fhtrace_L01.bin" \
         "82:3367:/tmp/fhtrace_L02.bin" "83:3395:/tmp/fhtrace_L03.bin" "86:3517:/tmp/fhtrace_L06.bin" \
         "90:3681:/tmp/fhtrace_L10.bin" "95:3886:/tmp/fhtrace_L15.bin" "101:4131:/tmp/fhtrace_L20.bin" \
         "108:4417:/tmp/fhtrace_P133.bin" "139:5685:/tmp/fhtrace_P162.bin" "264:10798:/tmp/fhtrace_P273.bin" )
echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
cleanup(){ sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; }
trap cleanup EXIT
# UL throughput = UPF tun0 rx_bytes delta (cumulative kernel counter via netlink; immune to
# rfsim bursty delivery + iperf3 reporting flakiness). iperf3 only GENERATES the load.
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
measure(){  # $1=trace -> sets meas(UL wall Mbps via tun0 delta) R loss
  echo "$1" > /tmp/fh_trace_path; sleep 4
  ping -I "$UE_IP" -c 2 -W 2 10.0.0.1 >/dev/null 2>&1
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
  sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/sw_srv.log -D; sleep 1
  local b0 b1 n0 t0 t1 n1; b0=$(rxb); n0=$(grep -c "stats sfn" $U); t0=$(date +%s.%N)
  timeout 32 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 50M -t 22 >/dev/null 2>&1
  t1=$(date +%s.%N); b1=$(rxb); n1=$(grep -c "stats sfn" $U)
  R=$(awk "BEGIN{print ($t1-$t0>0)?($n1-$n0)*1.28/($t1-$t0):0}")
  meas=$(awk "BEGIN{w=$t1-$t0; print (w>0 && \"$b1\"!=\"\" && \"$b0\"!=\"\")?($b1-$b0)*8/1e6/w:0}")
  loss=$(grep -oE "dropped [0-9]+/[0-9]+ pkts \([0-9.]+%\)" $G | tail -6 | grep -oE "\([0-9.]+%\)" | tr -d '()%' | awk '{s+=$1;n++}END{print (n>0)?s/n:0}')
  [[ "$1" = "off" ]] && loss=0
}
echo "[sweep] attaching (4RX, UL-ping gated)..."; attach || { echo "ATTACH FAILED"; exit 1; }
echo "[sweep] GOOD ATTACH UE_IP=$UE_IP"
printf "\n%-5s %-8s %-7s %-11s %-7s %-9s\n" "PRB" "FHload" "loss%" "UL_wall" "R" "calReal"
RESULTS=/tmp/sweep_results.csv; echo "PRB,FHload_Mbps,fh_loss_pct,ul_wall_Mbps,clock_R,cal_real_Mbps" > $RESULTS
for p in "${POINTS[@]}"; do
  PRB=${p%%:*}; rest=${p#*:}; FHL=${rest%%:*}; TR=${rest#*:}
  cur=$(ip -4 -o addr show oaitun_ue1 2>/dev/null|awk '{print $4}'|cut -d/ -f1|head -1)
  [[ -z "$cur" ]] && { echo "  [reattach before PRB=$PRB]"; attach || { echo "  reattach failed, skip $PRB"; continue; }; }
  measure "$TR"
  cal=$(awk "BEGIN{print ($R>0)?$meas/$R:$meas}")
  printf "%-5s %-8s %-7s %-11s %-7s %-9s\n" "$PRB" "$FHL" "$(printf %.1f ${loss:-0})" "$(printf %.1f $meas)" "$(printf %.2f $R)" "$(printf %.2f $cal)"
  echo "$PRB,$FHL,$loss,$meas,$R,$cal" >> $RESULTS
done
echo; echo "[sweep] done -> $RESULTS"
