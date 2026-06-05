#!/bin/bash
# Clean-tree rfsim: attach once, sweep injected FH latency in-session, measure UL throughput.
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
GNB_CONF="$BASE/gnb_clean_106.conf"; UE_CONF="$BASE/nrue_clean.conf"
BW_RB=106; UE_C=3319680000
LEVELS="${LEVELS:-0 300 400 450 500 550 600}"   # injected mean FH latency (us); budget 500 jitter 100
PER_SECS="${PER_SECS:-8}"; RATE="${RATE:-200M}"
MAX_TRIES="${MAX_TRIES:-8}"; UE_WAIT="${UE_WAIT:-28}"
GLOG=/tmp/rfs_gnb.log; ULOG=/tmp/rfs_ue.log; OUT=/tmp/rfs_sweep.csv
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_odr_violation=0}"
export FH_TA4_BUDGET_US="${FH_TA4_BUDGET_US:-500}" FH_JITTER_US="${FH_JITTER_US:-100}"
echo 0 > /tmp/fh_inject_us   # off during attach
echo "fh_inject_us,ul_mbps,drop_pct,jitter_ms,loss_pct" > "$OUT"

UE_IP=""
for try in $(seq 1 $MAX_TRIES); do
  echo "===== attach attempt $try/$MAX_TRIES ====="
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2
  : > "$GLOG"; : > "$ULOG"
  sudo -E taskset -c 4,5,6,7,8,9,10,11,12,13,14,15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" FH_TA4_BUDGET_US="$FH_TA4_BUDGET_US" FH_JITTER_US="$FH_JITTER_US" \
    "$BUILD/nr-softmodem" -O "$GNB_CONF" --rfsim >"$GLOG" 2>&1 &
  ok=0; for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" "$GLOG" && { ok=1; break; }; grep -qE "Exiting OAI" "$GLOG" && break; done
  [[ $ok = 1 ]] || { echo "  gNB no NGSetup"; continue; }
  sleep 2
  sudo taskset -c 16,17,18,19,20,21,22,23,24,25,26,27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
    "$BUILD/nr-uesoftmodem" -O "$UE_CONF" --rfsim -C "$UE_C" -r "$BW_RB" --numerology 1 >"$ULOG" 2>&1 &
  UPID=$!
  for i in $(seq 1 $UE_WAIT); do sleep 1; UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1); [[ -n "$UE_IP" ]] && break; kill -0 $UPID 2>/dev/null || break; done
  [[ -n "$UE_IP" ]] && { echo "  ATTACHED UE IP=$UE_IP"; break; }
  echo "  no attach (sync=$(grep -c 'Initial sync success' "$ULOG") sib1=$(grep -c 'SIB1 decoded' "$ULOG"))"
done
[[ -z "$UE_IP" ]] && { echo "[!] NO ATTACH"; sudo pkill -9 -x nr-softmodem; sudo pkill -9 -x nr-uesoftmodem; exit 1; }

UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf 2>/dev/null)
SRVLOG=/tmp/rfs_srv.log; rm -f "$SRVLOG"
sudo nsenter -t "$UPF_PID" -n pkill -x iperf3 2>/dev/null; sleep 1
sudo nsenter -t "$UPF_PID" -n iperf3 -s -B 10.0.0.1 -p 5201 --logfile "$SRVLOG" -D; sleep 1
echo "===== SWEEP (budget=${FH_TA4_BUDGET_US}us jitter=${FH_JITTER_US}us rate=${RATE}) ====="
printf "%-12s %-10s %-9s %-9s %s\n" "inject_us" "UL_Mbps" "drop%" "jit_ms" "loss%"
for lvl in $LEVELS; do
  echo "$lvl" > /tmp/fh_inject_us
  sleep 2
  before=$(wc -l < "$SRVLOG" 2>/dev/null || echo 0)
  timeout $((PER_SECS+12)) iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b "$RATE" -t "$PER_SECS" >"/tmp/rfs_cli_${lvl}.txt" 2>&1
  sleep 1
  # server-side received summary (robust under loss): last rate line from THIS test's new log lines
  srv=$(tail -n +$((before+1)) "$SRVLOG" 2>/dev/null | grep -E "bits/sec" | tail -1)
  ul=$(echo "$srv" | grep -oE "[0-9.]+ [KMG]?bits/sec" | head -1 | awk '{r=$1;u=$2; if(u~/K/)r/=1000; else if(u~/G/)r*=1000; else if(u!~/[KMG]/)r/=1e6; printf "%.2f",r}')
  jit=$(echo "$srv" | grep -oE "[0-9.]+ ms" | head -1 | grep -oE "[0-9.]+")
  loss=$(echo "$srv" | grep -oE "\([0-9.]+%?\)" | tr -d '()%' | head -1)
  ul=${ul:-NA}; jit=${jit:-NA}; loss=${loss:-NA}
  drop=$(grep "FH-inject:" "$GLOG" | tail -1 | grep -oE "\([0-9.]+%\)" | tr -d '()%')
  drop=${drop:-0}
  printf "%-12s %-10s %-9s %-9s %s\n" "$lvl" "$ul" "$drop" "$jit" "$loss"
  echo "$lvl,$ul,$drop,$jit,$loss" >> "$OUT"
done
echo 0 > /tmp/fh_inject_us
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
echo "[done] CSV: $OUT"
