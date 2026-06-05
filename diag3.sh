#!/bin/bash
# Robust attach GATED BY A UL PING (UE->UPF) -> reliably rejects the dead-UL attach
# mode. Then saturate with iperf3 -b 200M and read the gNB MAC UL goodput (iperf3's
# own report dies under saturation, but the MAC counter is valid). Quick off-vs-loss
# check to confirm goodput drops with FH loss.
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/d3_gnb.log; U=/tmp/d3_ue.log
echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
UE_IP=""
for try in $(seq 1 12); do
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2; : > $G; : > $U
  sudo -E taskset -c 4-15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-softmodem" -O $BASE/gnb_clean_106.conf --rfsim >$G 2>&1 &
  ok=0; for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" $G && { ok=1; break; }; done; [[ $ok = 1 ]] || continue
  sleep 2
  sudo taskset -c 16-27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-uesoftmodem" -O $BASE/nrue_clean.conf --rfsim -C 3319680000 -r 106 --numerology 1 >$U 2>&1 &
  sib=0; for i in $(seq 1 18); do sleep 1; grep -qE "SIB1 decoded|Found SIB1" $U && { sib=1; break; }; done; [[ $sib = 1 ]] || continue
  for i in $(seq 1 40); do sleep 1; UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null|awk '{print $4}'|cut -d/ -f1|head -1); [[ -n "$UE_IP" ]] && break; done
  [[ -z "$UE_IP" ]] && continue
  # UL-PING GATE: UE->UPF must get replies (proves the UL data plane is alive)
  pr=$(ping -I "$UE_IP" -c 5 -W 2 10.0.0.1 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+')
  echo "  try $try: UE_IP=$UE_IP  UL-ping replies=${pr:-0}/5"
  [[ "${pr:-0}" -ge 2 ]] && break
  UE_IP=""
done
[[ -z "$UE_IP" ]] && { echo "ATTACH(+UL) FAILED"; exit 1; }
echo "GOOD ATTACH UE_IP=$UE_IP"
NL=$BASE/nicloss
blast(){ # $1=trace  -> median nonzero gNB UL goodput (wall) + nicloss delivered + R
  echo "$1" > /tmp/fh_trace_path; sleep 4
  ping -I "$UE_IP" -c 2 -W 2 10.0.0.1 >/dev/null 2>&1
  sudo nsenter -t $UPF_PID -n pkill -x nicloss 2>/dev/null; sleep 1
  sudo nsenter -t $UPF_PID -n $NL recv 5301 6 >/tmp/d3_nlr.log 2>&1 &
  sleep 1
  local gl0 n0 t0 t1 n1
  gl0=$(wc -l < $G); n0=$(grep -c "stats sfn" $U); t0=$(date +%s.%N)
  $NL send 10.0.0.1 5301 60 14 2>/dev/null           # 60Mbps UDP, no control channel
  t1=$(date +%s.%N); n1=$(grep -c "stats sfn" $U); sleep 6
  local R=$(awk "BEGIN{print ($t1-$t0>0)?($n1-$n0)*1.28/($t1-$t0):0}")
  local samples=$(tail -n +$((gl0+1)) $G | grep -oE 'ulsch_rounds.*goodput [0-9.]+ Mbps' | grep -oE 'goodput [0-9.]+' | grep -oE '[0-9.]+')
  local med=$(echo "$samples" | awk '$1>0' | sort -n | awk '{a[NR]=$1}END{print (NR>0)?a[int((NR+1)/2)]:0}')
  local recvd=$(grep -oE "recvd=[0-9]+" /tmp/d3_nlr.log|cut -d= -f2)
  local nlr=$(awk "BEGIN{w=$t1-$t0; print (w>0)?${recvd:-0}*1400*8/1e6/w:0}")
  echo "$1 : gNB_UL_median=${med:-0} Mbps  nicloss_delivered=$(printf %.1f $nlr) Mbps (wall)  R=$(printf %.2f $R)  cal_gNB=$(awk "BEGIN{print ($R>0)?${med:-0}/$R:0}")"
}
echo "== off (0% loss) =="; blast off
echo "== P162 (42% loss) =="; blast /tmp/fhtrace_P162.bin
echo "== P273 (69% loss) =="; blast /tmp/fhtrace_P273.bin
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
