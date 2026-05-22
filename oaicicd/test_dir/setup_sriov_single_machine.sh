#!/usr/bin/env bash
set -euo pipefail

: "${PCI_DEVICE:?Set PCI_DEVICE to the PF PCI address, for example 0000:c1:00.0}"
: "${DPDK_INST:?Set DPDK_INST to the DPDK install directory}"
: "${TEST_DIR:?Set TEST_DIR to the OAI test_dir path}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo PCI_DEVICE=... DPDK_INST=... TEST_DIR=... bash $0" >&2
  exit 1
fi

PF_SYSFS="/sys/bus/pci/devices/${PCI_DEVICE}"
if [ ! -d "${PF_SYSFS}" ]; then
  echo "PCI device ${PCI_DEVICE} not found under /sys/bus/pci/devices" >&2
  exit 1
fi

if [ ! -f "${PF_SYSFS}/sriov_totalvfs" ]; then
  echo "PCI device ${PCI_DEVICE} does not expose sriov_totalvfs" >&2
  exit 1
fi

MAX_VFS=$(cat "${PF_SYSFS}/sriov_totalvfs")
if [ "${MAX_VFS}" -lt 5 ]; then
  echo "PCI device ${PCI_DEVICE} supports only ${MAX_VFS} VFs; need at least 5" >&2
  exit 1
fi

PF_IF=""
if [ -d "${PF_SYSFS}/net" ]; then
  for net_path in "${PF_SYSFS}"/net/*; do
    [ -e "${net_path}" ] || continue
    PF_IF=$(basename "${net_path}")
    break
  done
fi
if [ -z "${PF_IF}" ]; then
  echo "No network interface found for PCI device ${PCI_DEVICE}" >&2
  exit 1
fi

DPDK_DEVBIND="${DPDK_INST}/usertools/dpdk-devbind.py"
if [ ! -x "${DPDK_DEVBIND}" ]; then
  echo "dpdk-devbind.py not found or not executable: ${DPDK_DEVBIND}" >&2
  exit 1
fi

pci_addr() {
  local vf_index="$1"
  local vf_path="${PF_SYSFS}/virtfn${vf_index}"
  if [ ! -e "${vf_path}" ]; then
    echo "VF ${vf_index} not found for ${PF_IF}" >&2
    exit 1
  fi
  basename "$(readlink "${vf_path}")"
}

OUT_FILE="${TEST_DIR}/sriov_single_machine.txt"
NUM_VFS=5
MTU=9000
MACS=(
  "00:11:22:33:64:66"
  "00:11:22:33:64:67"
  "00:11:22:33:64:68"
  "00:11:22:33:64:69"
  "00:11:22:33:64:70"
)
VLANS=(3 4 3 4 3)
LABELS=(
  "O-RU VF 0 (U-plane)"
  "O-RU VF 1 (C-plane)"
  "gNB  VF 2 (U-plane)"
  "gNB  VF 3 (C-plane)"
  "Capture VF 4       "
)
DRIVERS=(vfio-pci vfio-pci vfio-pci vfio-pci iavf)

ip link set "${PF_IF}" up
if command -v ethtool >/dev/null 2>&1; then
  ethtool -G "${PF_IF}" rx 8160 tx 8160 >/dev/null 2>&1 || true
fi

echo 0 > "${PF_SYSFS}/sriov_numvfs"
echo "${NUM_VFS}" > "${PF_SYSFS}/sriov_numvfs"
sleep 1

modprobe vfio-pci
modprobe iavf || true

VF_PCIS=()
for i in 0 1 2 3 4; do
  VF_PCIS+=("$(pci_addr "${i}")")
  ip link set "${PF_IF}" vf "${i}" mac "${MACS[$i]}" vlan "${VLANS[$i]}" spoofchk off
  ip link set "${PF_IF}" vf "${i}" trust on 2>/dev/null || true
done

for i in 0 1 2 3; do
  "${DPDK_DEVBIND}" --unbind "${VF_PCIS[$i]}" >/dev/null 2>&1 || true
  "${DPDK_DEVBIND}" --bind=vfio-pci "${VF_PCIS[$i]}"
done

# Keep VF 4 on the kernel iavf driver so tcpdump and other host tools can capture traffic.
"${DPDK_DEVBIND}" --unbind "${VF_PCIS[4]}" >/dev/null 2>&1 || true
if ! "${DPDK_DEVBIND}" --bind=iavf "${VF_PCIS[4]}" >/dev/null 2>&1; then
  echo iavf > "/sys/bus/pci/devices/${VF_PCIS[4]}/driver_override"
  echo "${VF_PCIS[4]}" > /sys/bus/pci/drivers_probe
fi

{
  echo "PF Interface: ${PF_IF}"
  echo "PF PCI: ${PCI_DEVICE}"
  echo "VF Assignments:"
  for i in 0 1 2 3 4; do
    printf "  %s: %s MAC=%s VLAN=%s (%s)\n" "${LABELS[$i]}" "${VF_PCIS[$i]}" "${MACS[$i]}" "${VLANS[$i]}" "${DRIVERS[$i]}"
  done
} | tee "${OUT_FILE}"

echo "Wrote ${OUT_FILE}"
