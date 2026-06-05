#!/bin/bash
# Nail down a SATURATING UL measurement that survives the rfsim. iperf3 UDP at high
# -b starves its own TCP control channel -> 0. So: blast UL with a control-less UDP
# source and read the gNB MAC UL goodput (true delivered UL, jitter-robust).
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/d2_gnb.log; U=/tmp/d2_ue.log; NL=$BASE/nicloss
echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
UE_IP=""
for try in $(seq 1 8); do
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2; : > $G; : > $U
  sudo -E taskset -c 4-15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-softmodem" -O $BASE/gnb_clean_106.conf --rfsim >$G 2>&1 &
  ok=0; for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" $G && { ok=1; break; }; done; [[ $ok = 1 ]] || continue
  sleep 2
  sudo taskset -c 16-27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" "$BUILD/nr-uesoftmodem" -O $BASE/nrue_clean.conf --rfsim -C 3319680000 -r 106 --numerology 1 >$U 2>&1 &
  sib=0; for i in $(seq 1 18); do sleep 1; grep -qE "SIB1 decoded|Found SIB1" $U && { sib=1; break; }; done; [[ $sib = 1 ]] || continue
  for i in $(seq 1 40); do sleep 1; UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null|awk '{print $4}'|cut -d/ -f1|head -1); [[ -n "$UE_IP" ]] && break; done
  [[ -n "$UE_IP" ]] && break
done
[[ -z "$UE_IP" ]] && { echo "ATTACH FAILED"; exit 1; }
echo "ATTACHED UE_IP=$UE_IP"
sudo nsenter -t $UPF_PID -n ping -c 3 -W 2 "$UE_IP" >/dev/null 2>&1
echo "== low-rate iperf3 sanity (-b 30M) =="
sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/d2_srv.log -D; sleep 1
timeout 16 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 30M -t 8 >/dev/null 2>&1
echo "  iperf rx: $(grep receiver /tmp/d2_srv.log | grep -oE '[0-9.]+ [MK]bits/sec' | tail -1)"

echo "== METHOD A: iperf3 -b 200M blast, READ gNB MAC UL goodput =="
gl0=$(wc -l < $G)
timeout 22 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 200M -t 12 >/dev/null 2>&1
echo "  gNB UL goodput samples (Mbps): $(tail -n +$((gl0+1)) $G | grep -oE 'ulsch_rounds.*goodput [0-9.]+ Mbps' | grep -oE 'goodput [0-9.]+' | grep -oE '[0-9.]+' | tr '\n' ' ')"

echo "== METHOD B: nicloss UDP blast (no control channel) UE->UPF, read gNB goodput + recv =="
sudo nsenter -t $UPF_PID -n $NL recv 5301 6 >/tmp/d2_nlr.log 2>&1 &
sleep 1; gl1=$(wc -l < $G); n0=$(grep -c "stats sfn" $U); t0=$(date +%s.%N)
$NL send 10.0.0.1 5301 0 12 2>/tmp/d2_nls.log
t1=$(date +%s.%N); n1=$(grep -c "stats sfn" $U); sleep 6
R=$(awk "BEGIN{print ($t1-$t0>0)?($n1-$n0)*1.28/($t1-$t0):0}")
echo "  nicloss sender: $(cat /tmp/d2_nls.log)"
echo "  nicloss recv  : $(grep RECV /tmp/d2_nlr.log)"
echo "  gNB UL goodput samples (Mbps): $(tail -n +$((gl1+1)) $G | grep -oE 'ulsch_rounds.*goodput [0-9.]+ Mbps' | grep -oE 'goodput [0-9.]+' | grep -oE '[0-9.]+' | tr '\n' ' ')"
echo "  clock R=$R"
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
