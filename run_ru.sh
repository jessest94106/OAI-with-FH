#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${HOME}/oran_lab"
TEST_DIR="${BASE_DIR}/oaicicd/test_dir"
DPDK_INST="${TEST_DIR}/dpdk-stable-20.11.9"
OAI_DIR="${TEST_DIR}/openairinterface5g"
BUILD_DIR="${OAI_DIR}/build"
RU_CONF="${BASE_DIR}/ru_test.conf"
RU_CORES="${RU_CORES:-10,11,12,13,14,15,16}"
DPDK_DRIVER="${DPDK_DRIVER:-uio_pci_generic}"
ORU_PRACH_FRAME_ADJUST="${ORU_PRACH_FRAME_ADJUST:-0}"
RU_NUMEROLOGY="${RU_NUMEROLOGY:-1}"

SCRIPT_NAME="$(basename "$0" .sh)"
LOG_DIR="${BASE_DIR}/logs/${SCRIPT_NAME}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S)_pid$$.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Logging terminal output to ${LOG_FILE}"
echo "RU cores: ${RU_CORES}"
echo "RU numerology: ${RU_NUMEROLOGY}"
echo "ORU PRACH frame adjust: ${ORU_PRACH_FRAME_ADJUST}"

for path in "${BUILD_DIR}/nr-oru" "${BUILD_DIR}/libvrtsim.so" "${RU_CONF}" "${DPDK_INST}/usertools/dpdk-devbind.py"; do
  if [[ ! -e "${path}" ]]; then
    echo "Missing required path: ${path}" >&2
    exit 1
  fi
done

check_vfio_group_viability() {
  local pci group dev member driver blockers=0
  local devices=()

  mapfile -t devices < <(grep -m1 "dpdk_devices" "${RU_CONF}" | grep -oE "0000:[0-9a-fA-F:.]+")
  if (( ${#devices[@]} == 0 )); then
    echo "Could not parse dpdk_devices from ${RU_CONF}" >&2
    exit 1
  fi

  for pci in "${devices[@]}"; do
    if [[ ! -d "/sys/bus/pci/devices/${pci}" ]]; then
      echo "Configured RU DPDK device ${pci} does not exist. Run ${BASE_DIR}/prepare_network.sh first." >&2
      exit 1
    fi

    driver="$(basename "$(readlink -f "/sys/bus/pci/devices/${pci}/driver" 2>/dev/null || echo none)")"
    if [[ "${driver}" != "${DPDK_DRIVER}" ]]; then
      echo "Configured RU DPDK device ${pci} is bound to ${driver}, not ${DPDK_DRIVER}. Run DPDK_DRIVER=${DPDK_DRIVER} ${BASE_DIR}/prepare_network.sh first." >&2
      exit 1
    fi

    group="$(readlink -f "/sys/bus/pci/devices/${pci}/iommu_group" 2>/dev/null || true)"
    if [[ -z "${group}" ]]; then
      echo "Configured RU DPDK device ${pci} has no IOMMU group." >&2
      exit 1
    fi

    for dev in "${group}"/devices/*; do
      [[ -e "${dev}" ]] || continue
      member="$(basename "${dev}")"
      driver="$(basename "$(readlink -f "${dev}/driver" 2>/dev/null || echo none)")"
      if [[ "${driver}" != "vfio-pci" && "${driver}" != "none" ]]; then
        if (( blockers == 0 )); then
          echo "VFIO group is not viable for RU DPDK devices from ${RU_CONF}:" >&2
        fi
        echo "  blocker: ${member} driver=${driver}" >&2
        blockers=1
      fi
    done
  done

  if (( blockers )); then
    cat >&2 <<MSG

DPDK will fail with: VFIO group is not viable.
Fix by moving the NIC to an isolated IOMMU group or booting with ACS override,
for example: amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction
Then reboot and rerun ${BASE_DIR}/prepare_network.sh.
MSG
    exit 1
  fi
}

export TEST_DIR DPDK_INST
export C_INCLUDE_PATH="${DPDK_INST}/include"
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD_DIR}:${DPDK_INST}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
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

if [[ "${DPDK_DRIVER}" == "vfio-pci" ]]; then
  check_vfio_group_viability
else
  echo "Using ${DPDK_DRIVER}; skipping VFIO IOMMU group viability check."
fi

sudo rm -rf /var/run/dpdk/ru 2>/dev/null || true
sudo rm -f /tmp/vrtsim_connection /dev/shm/vrtsim* 2>/dev/null || true

cd "${BUILD_DIR}"
exec sudo -E chrt -f 95 taskset -c "${RU_CORES}" env \
  XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
  ASAN_OPTIONS="${ASAN_OPTIONS}" \
  XRAN_SKIP_LINK_CHECK="${XRAN_SKIP_LINK_CHECK}" \
  ORU_PRACH_FRAME_ADJUST="${ORU_PRACH_FRAME_ADJUST}" \
  OAI_ALLOW_BFP16="${OAI_ALLOW_BFP16:-}" \
  XRAN_TIMESCALE="${XRAN_TIMESCALE:-1.0}" \
  XRAN_TIME_EPOCH="${XRAN_TIME_EPOCH:-0}" \
  VRTSIM_UL_READ_ADVANCE="${VRTSIM_UL_READ_ADVANCE:-}" \
  ORU_PRACH_SAMPLE_SHIFT="${ORU_PRACH_SAMPLE_SHIFT:-}" \
  VRTSIM_UL_NOISE_STD="${VRTSIM_UL_NOISE_STD:-}" \
  VRTSIM_UL_MU_STEER="${VRTSIM_UL_MU_STEER:-}" \
  VRTSIM_UL_MU_STEER_BOOT="${VRTSIM_UL_MU_STEER_BOOT:-}" \
  VRTSIM_UL_MU_TV="${VRTSIM_UL_MU_TV:-}" \
  VRTSIM_UL_MU_DS="${VRTSIM_UL_MU_DS:-}" \
  VRTSIM_IMP_CFO_HZ="${VRTSIM_IMP_CFO_HZ:-}" \
  VRTSIM_IMP_IQ="${VRTSIM_IMP_IQ:-}" \
  VRTSIM_IMP_PN_HZ="${VRTSIM_IMP_PN_HZ:-}" \
  VRTSIM_IMP_PA_IBO_DB="${VRTSIM_IMP_PA_IBO_DB:-}" \
  VRTSIM_IMP_SEED="${VRTSIM_IMP_SEED:-}" \
  VRTSIM_IMP_AFTER_ATTACH="${VRTSIM_IMP_AFTER_ATTACH:-}" \
  ORU_FRAMEGRID_SNAP="${ORU_FRAMEGRID_SNAP:-}" \
  ORU_FRAMEGRID_SNAP_SLOTS="${ORU_FRAMEGRID_SNAP_SLOTS:-}" \
  VRTSIM_UL_ATTEN_SHIFT="${VRTSIM_UL_ATTEN_SHIFT:-}" \
  ORU_UL_LABEL_SHIFT="${ORU_UL_LABEL_SHIFT:-}" \
  ORU_UL_NOISE_STD="${ORU_UL_NOISE_STD:-}" \
  ORU_UL_NOISE_ANT_MASK="${ORU_UL_NOISE_ANT_MASK:-}" \
  ./nr-oru \
    -O "${RU_CONF}" \
    --vrtsim.role server \
    --numerology "${RU_NUMEROLOGY}" \
    ${VRTSIM_RU_EXTRA_ARGS:-}
