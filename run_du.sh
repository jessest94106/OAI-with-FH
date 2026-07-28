#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${HOME}/oran_lab"
TEST_DIR="${BASE_DIR}/oaicicd/test_dir"
DPDK_INST="${TEST_DIR}/dpdk-stable-20.11.9"
OAI_DIR="${TEST_DIR}/openairinterface5g"
BUILD_DIR="${OAI_DIR}/build"
DU_CONF="${BASE_DIR}/du_test.conf"
DU_CORES="${DU_CORES:-4,5,6,7,8,9,17,18}"
DU_THREAD_POOL="${DU_THREAD_POOL:-4,5,6,7}"
DU_NUMEROLOGY="${DU_NUMEROLOGY:-1}"

SCRIPT_NAME="$(basename "$0" .sh)"
LOG_DIR="${BASE_DIR}/logs/${SCRIPT_NAME}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S)_pid$$.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Logging terminal output to ${LOG_FILE}"
echo "DU cores: ${DU_CORES}"
echo "DU numerology: ${DU_NUMEROLOGY}"

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
export XRAN_SKIP_LINK_CHECK="${XRAN_SKIP_LINK_CHECK:-1}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

REQUIRED_HUGEPAGES="${REQUIRED_HUGEPAGES:-8192}"
current_hp="$(cat /proc/sys/vm/nr_hugepages)"
if (( current_hp < REQUIRED_HUGEPAGES )); then
  echo "Allocating ${REQUIRED_HUGEPAGES} hugepages; currently ${current_hp}."
  echo "${REQUIRED_HUGEPAGES}" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
fi
grep Huge /proc/meminfo

sudo rm -rf /var/run/dpdk/gnb /var/run/dpdk/du /var/run/dpdk/wls_0 2>/dev/null || true
sudo rm -f /dev/hugepages/wls_0map_* 2>/dev/null || true

DU_DPDK_DEVICE_COUNT="$(grep -m1 "dpdk_devices" "${DU_CONF}" | grep -oE "0000:[0-9a-fA-F:.]+" | wc -l)"
if (( DU_DPDK_DEVICE_COUNT > 1 )); then
  # Watchdog: the i40e PF sometimes drops the link-state-enable event to VF3
  # (gNB C-plane) during DPDK probe, leaving port 1 stuck in the link-check
  # loop forever.  After port 0 comes up, kick VF3 until port 1 also comes up.
  _PF_IFACE="eno1np0"
  _GNB_CP_VF=3
  _LOG="${LOG_FILE}"
  (
    deadline=$(( $(date +%s) + 60 ))
    port0_seen=0
    while (( $(date +%s) < deadline )); do
      if grep -q "Port 1 Link Up" "${_LOG}" 2>/dev/null; then
        break
      fi
      if grep -q "Port 0 Link Up" "${_LOG}" 2>/dev/null; then
        if (( port0_seen == 0 )); then
          port0_seen=1
          sleep 1
        fi
        sudo ip link set dev "${_PF_IFACE}" vf "${_GNB_CP_VF}" state disable 2>/dev/null || true
        sleep 0.5
        sudo ip link set dev "${_PF_IFACE}" vf "${_GNB_CP_VF}" state enable  2>/dev/null || true
        sleep 2
      else
        sleep 0.2
      fi
    done
  ) &
fi

cd "${BUILD_DIR}"
exec sudo -E chrt -f 70 taskset -c "${DU_CORES}" env \
  XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  XRAN_SKIP_LINK_CHECK="${XRAN_SKIP_LINK_CHECK}" \
  XRAN_TIMESCALE="${XRAN_TIMESCALE:-1.0}" \
  XRAN_TIME_EPOCH="${XRAN_TIME_EPOCH:-0}" \
  OAI_FH_MAX_QUEUE_NO_JUMP="${OAI_FH_MAX_QUEUE_NO_JUMP:-8}" \
  OAI_FH_SPIN_CAP="${OAI_FH_SPIN_CAP:-2000}" \
  OAI_FH_UL_SLOT_DELAY="${OAI_FH_UL_SLOT_DELAY:-}" \
  OAI_FH_EXPECT_FRAGS="${OAI_FH_EXPECT_FRAGS:-}" \
  OAI_FH_RESET_OFFSET="${OAI_FH_RESET_OFFSET:-}" \
  OAI_ULSCH_TRACE_CAP="${OAI_ULSCH_TRACE_CAP:-}" \
  OAI_ALLOW_BFP16="${OAI_ALLOW_BFP16:-}" \
  OAI_PRACH_ONLY_PREAMBLE="${OAI_PRACH_ONLY_PREAMBLE:-}" \
  OAI_PUSCH_ANT_DEBUG="${OAI_PUSCH_ANT_DEBUG:-}" \
  OAI_MU_CHEST_DEBUG="${OAI_MU_CHEST_DEBUG:-}" \
  OAI_UL_MU_DMRS="${OAI_UL_MU_DMRS:-}" \
  OAI_UL_MU_FORCE_PORT="${OAI_UL_MU_FORCE_PORT:-}" \
  OAI_UL_MU_SCID="${OAI_UL_MU_SCID:-}" \
  OAI_UL_MU_FORCE_SCID="${OAI_UL_MU_FORCE_SCID:-}" \
  OAI_UL_MU_COSCHED="${OAI_UL_MU_COSCHED:-}" \
  OAI_UL_MU_PORTS="${OAI_UL_MU_PORTS:-}" \
  OAI_UL_MU_PORT_FLIP="${OAI_UL_MU_PORT_FLIP:-}" \
  OAI_UL_MU_IRC="${OAI_UL_MU_IRC:-}" \
  OAI_CATB_WEIGHT_EXPORT="${OAI_CATB_WEIGHT_EXPORT:-}" \
  OAI_CATB_BFW="${OAI_CATB_BFW:-}" \
  OAI_XRAN_CAT="${OAI_XRAN_CAT:-}" \
  OAI_UL_AVG_AGG="${OAI_UL_AVG_AGG:-}" \
  OAI_UL_MU_RHO_BYPASS="${OAI_UL_MU_RHO_BYPASS:-}" \
  OAI_UL_MU_MMSE="${OAI_UL_MU_MMSE:-}" \
  OAI_UL_MU_GENIE="${OAI_UL_MU_GENIE:-}" \
  OAI_UL_MU_SHIFT_ADJ="${OAI_UL_MU_SHIFT_ADJ:-}" \
  OAI_UL_MU_SHIFT_ADJ_HI="${OAI_UL_MU_SHIFT_ADJ_HI:-}" \
  OAI_UL_DMRS_ADDPOS="${OAI_UL_DMRS_ADDPOS:-}" \
  OAI_UL_MIXED_TDA="${OAI_UL_MIXED_TDA:-}" \
  OAI_UL_TDA14="${OAI_UL_TDA14:-}" \
  OAI_UL_MU_CH_AVG="${OAI_UL_MU_CH_AVG:-}" \
  OAI_MU_PAIR_SCREEN="${OAI_MU_PAIR_SCREEN:-}" \
  OAI_MSG3_PRB="${OAI_MSG3_PRB:-}" \
  OAI_UL_CHEST_GUARD="${OAI_UL_CHEST_GUARD:-}" \
  OAI_UL_FORCE_LAYERS="${OAI_UL_FORCE_LAYERS:-}" \
  ./nr-softmodem \
    -O "${DU_CONF}" \
    --gNBs.[0].min_rxtxtime "${MIN_RXTXTIME:-6}" \
    --thread-pool "${DU_THREAD_POOL}" \
    --numerology "${DU_NUMEROLOGY}" \
    ${DU_EXTRA_ARGS:-}
