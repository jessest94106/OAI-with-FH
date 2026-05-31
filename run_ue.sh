#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${HOME}/oran_lab"
TEST_DIR="${BASE_DIR}/oaicicd/test_dir"
DPDK_INST="${TEST_DIR}/dpdk-stable-20.11.9"
OAI_DIR="${TEST_DIR}/openairinterface5g"
BUILD_DIR="${OAI_DIR}/build"
UE_CORES="20,21,22,23"
UE_SSB="${RUN_UE_SSB:-24}"
UE_RB="${RUN_UE_RB:-24}"   # UE N_RB; must match carrier bandwidth (24=10MHz, 51=20MHz, 133=50MHz @ 30kHz SCS)
UE_CARRIER="${RUN_UE_CARRIER:-4049760000}"  # UE carrier CENTER (Hz); moves with bandwidth since pointA is fixed (center = pointA + N_RB*180kHz)
UE_SAMPLE_ADVANCE="${RUN_UE_SAMPLE_ADVANCE:-0}"

SCRIPT_NAME="$(basename "$0" .sh)"
LOG_DIR="${BASE_DIR}/logs/${SCRIPT_NAME}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S)_pid$$.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Logging terminal output to ${LOG_FILE}"
echo "UE cores: ${UE_CORES}"
echo "UE sample advance: ${UE_SAMPLE_ADVANCE}"

for path in "${BUILD_DIR}/nr-uesoftmodem" "${BUILD_DIR}/libvrtsim.so"; do
  if [[ ! -e "${path}" ]]; then
    echo "Missing required path: ${path}" >&2
    exit 1
  fi
done

if [[ ! -f /tmp/vrtsim_connection || ! -f /dev/shm/vrtsim_channel ]]; then
  echo "VRTSIM shared memory is not ready. Start ${BASE_DIR}/run_ru.sh first and wait for RU server setup." >&2
  exit 1
fi

if ! pgrep -x nr-oru >/dev/null; then
  echo "nr-oru is not running. Start ${BASE_DIR}/run_ru.sh first and keep it running." >&2
  exit 1
fi

echo "VRTSIM shared memory is ready; starting UE without waiting for non-zero DL samples."

export TEST_DIR DPDK_INST
export C_INCLUDE_PATH="${DPDK_INST}/include"
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD_DIR}:${DPDK_INST}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_odr_violation=0}"

cd "${BUILD_DIR}"
exec sudo -E taskset -c "${UE_CORES}" env \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  ./nr-uesoftmodem \
    -O "${BASE_DIR}/ue_test.conf" \
    -C "${UE_CARRIER}" \
    -r "${UE_RB}" \
    --numerology 1 \
    --band 77 \
    --ssb "${UE_SSB}" \
    -A "${UE_SAMPLE_ADVANCE}" \
    --device.name vrtsim \
    --vrtsim.role client \
    --ue-nb-ant-tx "${UE_NB_ANT_TX:-1}" \
    --ue-nb-ant-rx "${UE_NB_ANT_RX:-1}" \
    ${VRTSIM_UE_EXTRA_ARGS:-}
