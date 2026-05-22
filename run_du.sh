#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${HOME}/oran_lab"
TEST_DIR="${BASE_DIR}/oaicicd/test_dir"
DPDK_INST="${TEST_DIR}/dpdk-stable-20.11.9"
OAI_DIR="${TEST_DIR}/openairinterface5g"
BUILD_DIR="${OAI_DIR}/cmake_targets/ran_build/build"
DU_CONF="${BASE_DIR}/du_test.conf"
DU_CORES="${DU_CORES:-1,2,3,4,5,6,7,8,9,15}"
DU_THREAD_POOL="${DU_THREAD_POOL:-1,2,3,4}"

SCRIPT_NAME="$(basename "$0" .sh)"
LOG_DIR="${BASE_DIR}/logs/${SCRIPT_NAME}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S)_pid$$.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Logging terminal output to ${LOG_FILE}"
echo "DU cores: ${DU_CORES}"

for path in "${BUILD_DIR}/nr-softmodem" "${DU_CONF}" "${DPDK_INST}/usertools/dpdk-devbind.py"; do
  if [[ ! -e "${path}" ]]; then
    echo "Missing required path: ${path}" >&2
    exit 1
  fi
done

export TEST_DIR DPDK_INST
export C_INCLUDE_PATH="${DPDK_INST}/include"
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD_DIR}:${OAI_DIR}/build:${DPDK_INST}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_odr_violation=0}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

REQUIRED_HUGEPAGES="${REQUIRED_HUGEPAGES:-8192}"
current_hp="$(cat /proc/sys/vm/nr_hugepages)"
if (( current_hp < REQUIRED_HUGEPAGES )); then
  echo "Allocating ${REQUIRED_HUGEPAGES} hugepages; currently ${current_hp}."
  echo "${REQUIRED_HUGEPAGES}" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
fi
grep Huge /proc/meminfo

sudo rm -rf /var/run/dpdk/gnb /var/run/dpdk/du /var/run/dpdk/wls_0 2>/dev/null || true

cd "${BUILD_DIR}"
exec sudo -E taskset -c "${DU_CORES}" env \
  XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  ./nr-softmodem \
    -O "${DU_CONF}" \
    --gNBs.[0].min_rxtxtime 6 \
    --thread-pool "${DU_THREAD_POOL}"
