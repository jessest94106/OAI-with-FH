#!/bin/bash
# Robust UL throughput = UPF tun0 rx_bytes delta (cumulative kernel counter, immune to the
# rfsim's bursty delivery and to iperf3's flaky reporting). Just need iperf3 to GENERATE
# UL load; we count what actually arrives at the UPF. Controlled off->10%->42%->off.
BASE=/home/jesse/oran_lab; CONF=$BASE/gnb_clean_106_4rx.conf
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/qt_gnb.log; U=/tmp/qt_ue.log
echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
cleanup(){ sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; }
trap cleanup EXIT
# read tun0 RX bytes via netlink (respects netns; /sys needs the mount ns, which -n lacks)
rxb(){ sudo nsenter -t $UPF_PID -n ip -s link show tun0 | awk '/RX:/{getline; print $1; exit}'; }
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
  echo "  try $try: UE_IP=$UE_IP UL-ping=${pr:-0}/5"; [[ "${pr:-0}" -ge 2 ]] && break; UE_IP=""
done
[[ -z "$UE_IP" ]] && { echo "ATTACH FAILED"; exit 1; }
echo "GOOD 4RX ATTACH UE_IP=$UE_IP"
meas(){
  echo "$1" > /tmp/fh_trace_path; sleep 4
  ping -I "$UE_IP" -c 2 -W 2 10.0.0.1 >/dev/null 2>&1
  sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
  sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/qt_srv.log -D; sleep 1
  local b0 b1 n0 n1 t0 t1
  b0=$(rxb); n0=$(grep -c "stats sfn" $U); t0=$(date +%s.%N)
  timeout 32 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 50M -t 22 >/dev/null 2>&1
  t1=$(date +%s.%N); b1=$(rxb); n1=$(grep -c "stats sfn" $U)
  local R=$(awk "BEGIN{print ($t1-$t0>0)?($n1-$n0)*1.28/($t1-$t0):0}")
  local fh=$(grep -oE "dropped [0-9]+/[0-9]+ pkts \([0-9.]+%\)" $G | tail -6 | grep -oE "\([0-9.]+%\)" | tr -d '()%' | awk '{s+=$1;n++}END{print (n>0)?s/n:0}'); [[ "$1" = "off" ]] && fh=0
  awk "BEGIN{w=$t1-$t0; wall=($b1-$b0)*8/1e6/w; r=$R; printf \"%-26s FHloss=%4.1f%%  UL_wall=%6.2f Mbps  R=%4.2f  cal_real=%6.2f Mbps\n\",\"$2\",$fh,wall,r,(r>0)?wall/r:wall}"
}
meas off            "off (0%)"
meas /tmp/fhtrace_L10.bin  "L10 (10%)"
meas /tmp/fhtrace_P162.bin "P162 (42%)"
meas off            "off again (repeat)"
