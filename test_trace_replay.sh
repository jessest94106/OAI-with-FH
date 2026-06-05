#!/bin/bash
# End-to-end test of the trace-replay FH U-plane loss model.
# Robust attach (early SIB1-lock detection + retries), then load a measured
# drop-trace via /tmp/fh_trace_path and confirm the RU replays it on UL PUSCH.
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"
G=/tmp/t_gnb.log; U=/tmp/t_ue.log
TRACE=${1:-/tmp/fhtrace_133prb.bin}

echo off > /tmp/fh_trace_path; echo 0 > /tmp/fh_inject_loss; echo 0 > /tmp/fh_inject_us
UE_IP=""
for try in $(seq 1 8); do
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null
  sleep 2; : > $G; : > $U
  sudo -E taskset -c 4-15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
    "$BUILD/nr-softmodem" -O $BASE/gnb_clean_106.conf --rfsim >$G 2>&1 &
  ok=0
  for i in $(seq 1 30); do sleep 1; if grep -qE "Received NGSetupResponse" $G; then ok=1; break; fi; done
  if [[ $ok != 1 ]]; then echo "try $try: no NGSetup"; continue; fi
  sleep 2
  sudo taskset -c 16-27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
    "$BUILD/nr-uesoftmodem" -O $BASE/nrue_clean.conf --rfsim -C 3319680000 -r 106 --numerology 1 >$U 2>&1 &
  sib=0
  for i in $(seq 1 18); do sleep 1; if grep -qE "SIB1 decoded|Found SIB1" $U; then sib=1; break; fi; done
  if [[ $sib != 1 ]]; then echo "try $try: bad PBCH lock"; continue; fi
  for i in $(seq 1 40); do
    sleep 1
    UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$UE_IP" ]] && break
  done
  [[ -n "$UE_IP" ]] && break
done
if [[ -z "$UE_IP" ]]; then
  echo "ATTACH FAILED after retries"
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null
  exit 0
fi
echo "ATTACHED UE_IP=$UE_IP (try $try)"

# Generate UL traffic; mid-stream switch the trace path on so the L1 hook loads it.
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf)
sudo nsenter -t $UPF_PID -n pkill -x iperf3 2>/dev/null; sleep 1
sudo nsenter -t $UPF_PID -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/t_srv.log -D
sleep 1
echo "$TRACE" > /tmp/fh_trace_path
timeout 30 iperf3 -c 10.0.0.1 -p 5201 -B $UE_IP -u -b 200M -t 18 >/tmp/t_cli.log 2>&1
echo "---- results ----"
echo "FH-TRACE load : $(grep 'FH-TRACE' $G | tail -1)"
echo "FH-loss replay: $(grep 'FH-UPLANE-LOSS' $G | tail -2)"
echo "UL rx (server): $(grep -E 'receiver' /tmp/t_srv.log | grep -oE '[0-9.]+ [MK]bits/sec' | tail -1)"
echo "UE MAC stats  : $(grep -E 'stats sfn' $U | tail -1)"
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
echo done
