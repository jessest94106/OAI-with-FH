#!/bin/bash
# Clean-tree (2026.w22) rfsim attach + UL iperf. High-BW (106PRB/40MHz), my CN.
# Restart BOTH gNB+UE each try (rfsim server crashes on client reconnect).
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
GNB_CONF="${GNB_CONF:-$BASE/gnb_clean_106.conf}"
UE_CONF="${UE_CONF:-$BASE/nrue_clean.conf}"
BW_RB="${BW_RB:-106}"; UE_C="${UE_C:-3319680000}"
IPERF_SECS="${IPERF_SECS:-15}"; IPERF_RATE="${IPERF_RATE:-100M}"
MAX_TRIES="${MAX_TRIES:-4}"; UE_WAIT="${UE_WAIT:-40}"
GLOG=/tmp/rfc_gnb.log; ULOG=/tmp/rfc_ue.log
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_odr_violation=0}"

UE_IP=""
for try in $(seq 1 $MAX_TRIES); do
  echo "===== attempt $try/$MAX_TRIES ====="
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2
  : > "$GLOG"; : > "$ULOG"
  sudo -E taskset -c 4,5,6,7,8,9,10,11,12,13,14,15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
    "$BUILD/nr-softmodem" -O "$GNB_CONF" --rfsim >"$GLOG" 2>&1 &
  ok=0; for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" "$GLOG" && { ok=1; break; }
    grep -qE "Exiting OAI" "$GLOG" && break; done
  [[ $ok = 1 ]] || { echo "  gNB no NGSetup; retry"; continue; }
  echo "  gNB up (NGSetup). starting UE..."
  sleep 2
  sudo taskset -c 16,17,18,19,20,21,22,23,24,25,26,27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
    "$BUILD/nr-uesoftmodem" -O "$UE_CONF" --rfsim -C "$UE_C" -r "$BW_RB" --numerology 1 >"$ULOG" 2>&1 &
  UPID=$!
  for i in $(seq 1 $UE_WAIT); do sleep 1
    UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$UE_IP" ]] && break
    kill -0 $UPID 2>/dev/null || break
  done
  [[ -n "$UE_IP" ]] && { echo "  ATTACHED: UE IP=$UE_IP rrc=$(grep -c RRCSetupComplete "$ULOG") reg=$(grep -c 'Registration Accept' "$ULOG") pdu=$(grep -c 'PDU Session Establish' "$ULOG")"; break; }
  echo "  no attach: sync=$(grep -c 'Initial sync success' "$ULOG") sib1=$(grep -c 'SIB1 decoded' "$ULOG") rrc=$(grep -c RRCSetupComplete "$ULOG") reg=$(grep -c 'Registration Accept' "$ULOG") msg3f=$(grep -c 'no data for Msg3' "$ULOG") uedied=$(grep -c 'Exiting OAI' "$ULOG")"
done

if [[ -n "$UE_IP" ]]; then
  echo "[*] connectivity check (UE $UE_IP -> 10.0.0.1) ..."
  echo "  route: $(ip route get 10.0.0.1 from "$UE_IP" 2>&1 | head -1)"
  echo "  ping: $(ping -c 3 -W 2 -I "$UE_IP" 10.0.0.1 2>&1 | grep -E 'packets transmitted|rtt' | tr '\n' ' ')"
  UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf 2>/dev/null)
  sudo nsenter -t "$UPF_PID" -n pkill -x iperf3 2>/dev/null; sleep 1
  sudo nsenter -t "$UPF_PID" -n iperf3 -s -B 10.0.0.1 -p 5201 -D
  sleep 2
  echo "[*] UL iperf ${IPERF_SECS}s @ ${IPERF_RATE} (UDP) ..."
  timeout $((IPERF_SECS+15)) iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b "$IPERF_RATE" -t "$IPERF_SECS" -i 5 2>&1 | grep -E "bits/sec|Datagrams|connect|error|refused" | tail -6
else
  echo "[!] NO ATTACH after $MAX_TRIES tries"
fi
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
echo "[done]"
