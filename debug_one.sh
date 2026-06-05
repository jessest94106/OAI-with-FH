#!/bin/bash
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/dbg_gnb.log; U=/tmp/dbg_ue.log
echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UE_IP=""
for try in $(seq 1 10); do
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
echo "== route on UE tun =="; ip route get 10.0.0.1 2>&1 | head -2
echo "== ping UPF from UE (DL+UL path) =="; ping -I "$UE_IP" -c 4 -W 2 10.0.0.1 2>&1 | tail -5
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
echo "== ping UE from UPF =="; sudo nsenter -t $UPF_PID -n ping -c 4 -W 2 "$UE_IP" 2>&1 | tail -5
echo "== iperf UL (verbose client) =="
sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/dbg_srv.log -D; sleep 1
timeout 24 iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b 50M -t 12 2>&1 | tail -18
echo "== server side =="; tail -8 /tmp/dbg_srv.log
echo "== gNB UL MCS/goodput =="; grep -iE "goodput" $G | tail -2 | sed 's/\x1b\[[0-9;]*m//g'
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
