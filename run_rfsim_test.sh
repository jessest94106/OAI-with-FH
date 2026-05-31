#!/usr/bin/env bash
# Run gNB + UE via rfsim (no RU/FH), run iperf, report throughput.
set -euo pipefail

BASE_DIR="/home/jesse/oran_lab"
OAI_DIR="${BASE_DIR}/oaicicd/test_dir/openairinterface5g"
BUILD_DIR="${OAI_DIR}/build"
GNB_CONF="${BASE_DIR}/gnb_rfsim.conf"
UE_CONF="${BASE_DIR}/ue_test.conf"

UE_WAIT="${UE_WAIT:-25}"
IPERF_SECONDS="${IPERF_SECONDS:-20}"
LOG_DIR="${BASE_DIR}/logs/rfsim_test/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOG_DIR}"

GNB_LOG="${LOG_DIR}/gnb.log"
UE_LOG="${LOG_DIR}/ue.log"
IPERF_UL_JSON="${LOG_DIR}/iperf_ul.json"
IPERF_DL_JSON="${LOG_DIR}/iperf_dl.json"

GNB_PID=""
UE_PID=""

export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD_DIR}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_odr_violation=0}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() {
  set +e
  [[ -n "${UE_PID}"  ]] && sudo kill -TERM "${UE_PID}"  2>/dev/null; true
  [[ -n "${GNB_PID}" ]] && sudo kill -TERM "${GNB_PID}" 2>/dev/null; true
  sleep 1
  [[ -n "${UE_PID}"  ]] && sudo kill -KILL "${UE_PID}"  2>/dev/null; true
  [[ -n "${GNB_PID}" ]] && sudo kill -KILL "${GNB_PID}" 2>/dev/null; true
}
trap cleanup EXIT INT TERM

log "Logs → ${LOG_DIR}"

# --- start gNB ---
log "Starting gNB (rfsim)..."
sudo -E taskset -c 4,5,6,7,8,9 env \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  "${BUILD_DIR}/nr-softmodem" \
    -O "${GNB_CONF}" \
    --rfsim \
    --thread-pool 4,5,6,7 \
  >"${GNB_LOG}" 2>&1 &
GNB_PID=$!
log "gNB PID=${GNB_PID}"

# wait for gNB to be ready (rfsim server listening)
log "Waiting for gNB rfsim server..."
for i in $(seq 1 30); do
  sleep 1
  if grep -q "Listening on" "${GNB_LOG}" 2>/dev/null || \
     grep -q "rfsim.*listen\|server.*listen\|rfsim server" "${GNB_LOG}" 2>/dev/null || \
     grep -q "got sync\|Got sync\|DL freq\|Initialization" "${GNB_LOG}" 2>/dev/null; then
    break
  fi
  if ! kill -0 "${GNB_PID}" 2>/dev/null; then
    log "gNB exited early — see ${GNB_LOG}"
    tail -20 "${GNB_LOG}"
    exit 1
  fi
done
sleep 3  # extra settling time

# --- start UE ---
log "Starting UE (rfsim)..."
sudo -E taskset -c 20,21,22,23 env \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  "${BUILD_DIR}/nr-uesoftmodem" \
    -O "${UE_CONF}" \
    --rfsim \
    -C 4049760000 \
    -r 24 \
    --numerology 1 \
    --band 77 \
    --ssb 24 \
    -A 0 \
    --ue-nb-ant-tx 1 \
    --ue-nb-ant-rx 1 \
  >"${UE_LOG}" 2>&1 &
UE_PID=$!
log "UE PID=${UE_PID}"

# wait for PDU session
log "Waiting up to ${UE_WAIT}s for UE PDU session..."
UE_IP=""
deadline=$(( SECONDS + UE_WAIT ))
while (( SECONDS < deadline )); do
  sleep 1
  if ! kill -0 "${UE_PID}" 2>/dev/null; then
    log "UE exited early — see ${UE_LOG}"
    tail -20 "${UE_LOG}"
    exit 1
  fi
  UE_IP=$(grep -oP 'UE IPv4: \K[0-9.]+' "${UE_LOG}" 2>/dev/null | tail -1 || true)
  [[ -n "${UE_IP}" ]] && break
done

if [[ -z "${UE_IP}" ]]; then
  log "UE did not get IP within ${UE_WAIT}s"
  log "--- last 30 lines of UE log ---"
  tail -30 "${UE_LOG}"
  log "--- last 20 lines of gNB log ---"
  tail -20 "${GNB_LOG}"
  exit 1
fi

log "UE connected: IP=${UE_IP}"
sleep 3

# --- iperf UL ---
log "Running UL iperf (${IPERF_SECONDS}s) ..."
timeout $(( IPERF_SECONDS + 15 )) \
  iperf3 -J -c 10.0.0.1 -p 5201 -B "${UE_IP}" -t "${IPERF_SECONDS}" \
  >"${IPERF_UL_JSON}" 2>/dev/null || true

ul_mbps=$(python3 -c "
import json, sys
try:
  d = json.load(open('${IPERF_UL_JSON}'))
  print(f\"{d['end']['sum_sent']['bits_per_second']/1e6:.2f}\")
except: print('0.00')
" 2>/dev/null || echo "0.00")

# --- iperf DL ---
log "Running DL iperf (${IPERF_SECONDS}s) ..."
timeout $(( IPERF_SECONDS + 15 )) \
  iperf3 -J -c 10.0.0.1 -p 5201 -B "${UE_IP}" -R -t "${IPERF_SECONDS}" \
  >"${IPERF_DL_JSON}" 2>/dev/null || true

dl_mbps=$(python3 -c "
import json, sys
try:
  d = json.load(open('${IPERF_DL_JSON}'))
  print(f\"{d['end']['sum_received']['bits_per_second']/1e6:.2f}\")
except: print('0.00')
" 2>/dev/null || echo "0.00")

log "===== rfsim result: UL ${ul_mbps} Mbps  DL ${dl_mbps} Mbps ====="
log "Logs: ${LOG_DIR}"

# grab ULSCH trace summary from gNB log
nak_count=$(grep -c "ULSCH NAK" "${GNB_LOG}" 2>/dev/null || echo 0)
ack_count=$(grep -c "ULSCH ACK" "${GNB_LOG}" 2>/dev/null || echo 0)
log "ULSCH: ${ack_count} ACK  ${nak_count} NAK  (trace capped at 32 each)"
