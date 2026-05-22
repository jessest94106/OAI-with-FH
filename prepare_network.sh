#!/usr/bin/env bash
set -euo pipefail

# Prepare the current single-machine O-RAN 7.2 SR-IOV layout.
# Run as your normal user: bash ~/oran_lab/prepare_network.sh
# The script uses sudo internally only for privileged network/sysfs operations.

PF_PCI="${PF_PCI:-0000:05:00.0}"
PF_IFACE="${PF_IFACE:-}"
RUN_USER="${SUDO_USER:-${USER}}"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
RUN_HOME="${RUN_HOME:-${HOME}}"
BASE_DIR="${BASE_DIR:-${RUN_HOME}/oran_lab}"
TEST_DIR="${TEST_DIR:-${BASE_DIR}/oaicicd/test_dir}"
DPDK_INST="${DPDK_INST:-${TEST_DIR}/dpdk-stable-20.11.9}"
DEVBIND="${DEVBIND:-${DPDK_INST}/usertools/dpdk-devbind.py}"
OUT_FILE="${OUT_FILE:-${TEST_DIR}/sriov_single_machine.txt}"
NUM_VFS=5
MTU="${MTU:-9600}"
DPDK_DRIVER="${DPDK_DRIVER:-uio_pci_generic}"
CAPTURE_DRIVER="${CAPTURE_DRIVER:-iavf}"

VF_LABELS=(
  "O-RU VF 0 (U-plane)"
  "O-RU VF 1 (C-plane)"
  "gNB  VF 2 (U-plane)"
  "gNB  VF 3 (C-plane)"
  "Capture VF 4       "
)
VF_MACS=(
  "00:11:22:33:64:66"
  "00:11:22:33:64:67"
  "00:11:22:33:64:68"
  "00:11:22:33:64:69"
  "00:11:22:33:64:70"
)
VF_VLANS=(3 4 3 4 3)
VF_DRIVERS=("${DPDK_DRIVER}" "${DPDK_DRIVER}" "${DPDK_DRIVER}" "${DPDK_DRIVER}" "${CAPTURE_DRIVER}")

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

log() { printf "==> %s\n" "$*"; }
warn() { printf "WARNING: %s\n" "$*" >&2; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
run_priv() { "${SUDO[@]}" "$@"; }
write_sysfs() {
  local value="$1"
  local path="$2"
  printf "%s" "${value}" | run_priv tee "${path}" >/dev/null
}

find_pf_iface() {
  local net_path
  if [[ -n "${PF_IFACE}" ]]; then
    return
  fi
  [[ -d "/sys/bus/pci/devices/${PF_PCI}/net" ]] || die "No netdev directory for PF ${PF_PCI}"
  for net_path in /sys/bus/pci/devices/${PF_PCI}/net/*; do
    [[ -e "${net_path}" ]] || continue
    PF_IFACE="$(basename "${net_path}")"
    break
  done
  [[ -n "${PF_IFACE}" ]] || die "Could not determine PF interface for ${PF_PCI}"
}

pci_driver() {
  local pci="$1"
  basename "$(readlink -f "/sys/bus/pci/devices/${pci}/driver" 2>/dev/null || echo none)"
}

bind_device() {
  local pci="$1"
  local driver="$2"
  local current

  current="$(pci_driver "${pci}")"
  if [[ "${current}" == "${driver}" ]]; then
    log "${pci} already bound to ${driver}"
    return
  fi

  run_priv "${DEVBIND}" --unbind "${pci}" >/dev/null 2>&1 || true
  if ! run_priv "${DEVBIND}" --bind="${driver}" "${pci}"; then
    write_sysfs "${driver}" "/sys/bus/pci/devices/${pci}/driver_override"
    write_sysfs "${pci}" /sys/bus/pci/drivers_probe
  fi
  log "${pci} bound to ${driver}"
}

vf_pci_addr() {
  local vf_idx="$1"
  local vf_path="/sys/bus/pci/devices/${PF_PCI}/virtfn${vf_idx}"
  [[ -e "${vf_path}" ]] || die "Missing ${vf_path}; VFs were not created"
  basename "$(readlink "${vf_path}")"
}

check_vfio_group_viability() {
  local vf_pci group group_id dev pci driver blockers=0
  declare -A seen_groups=()

  for vf_pci in "${VF_PCIS[@]:0:4}"; do
    group="$(readlink -f "/sys/bus/pci/devices/${vf_pci}/iommu_group" 2>/dev/null || true)"
    [[ -n "${group}" ]] || die "${vf_pci} has no IOMMU group; enable IOMMU in BIOS/kernel"
    seen_groups["${group}"]=1
  done

  for group in "${!seen_groups[@]}"; do
    group_id="$(basename "${group}")"
    log "Checking VFIO viability for IOMMU group ${group_id}"
    for dev in "${group}"/devices/*; do
      [[ -e "${dev}" ]] || continue
      pci="$(basename "${dev}")"
      driver="$(pci_driver "${pci}")"
      if [[ "${driver}" != "vfio-pci" && "${driver}" != "none" ]]; then
        printf "  blocker: %s driver=%s\n" "${pci}" "${driver}" >&2
        blockers=1
      fi
    done
  done

  if (( blockers )); then
    cat >&2 <<MSG

VFIO group is not viable for DPDK.
DPDK cannot attach a VF while another PCI device in the same IOMMU group is
still bound to a non-vfio driver.

Do not blindly unbind every blocker; this group can include SATA, USB, PCI
bridges, Wi-Fi, the PF, or other live system devices.

Recommended fix for this workstation:
  1. Enable IOMMU in BIOS.
  2. Boot Linux with AMD IOMMU enabled and ACS override, for example:
       amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction
  3. Reboot, rerun this script, and confirm each DPDK VF has an isolated or
     otherwise viable IOMMU group.

This kernel may not support pcie_acs_override. For this lab, use the default
DPDK_DRIVER=uio_pci_generic mode in prepare_network.sh, or install a kernel
with ACS override support/move the NIC to an isolated PCIe slot.
MSG
    return 1
  fi
}

command -v sudo >/dev/null 2>&1 || [[ "${EUID}" -eq 0 ]] || die "sudo is required for network preparation"
[[ -d "/sys/bus/pci/devices/${PF_PCI}" ]] || die "PF PCI device not found: ${PF_PCI}"
[[ -x "${DEVBIND}" ]] || die "dpdk-devbind.py not executable: ${DEVBIND}"
find_pf_iface

if [[ "${EUID}" -ne 0 ]]; then
  log "Checking passwordless sudo for privileged network operations"
  run_priv true
fi

log "Using PF ${PF_IFACE} (${PF_PCI})"
log "Using DPDK devbind ${DEVBIND}"

log "Loading drivers"
run_priv modprobe vfio-pci || true
run_priv modprobe uio || true
run_priv modprobe uio_pci_generic || true
run_priv modprobe iavf || true

log "Resetting and creating ${NUM_VFS} VFs"
run_priv ip link set dev "${PF_IFACE}" up
run_priv ip link set dev "${PF_IFACE}" mtu "${MTU}" || warn "Could not set PF MTU ${MTU} on ${PF_IFACE}"
write_sysfs 0 "/sys/bus/pci/devices/${PF_PCI}/sriov_numvfs"
sleep 1
write_sysfs "${NUM_VFS}" "/sys/bus/pci/devices/${PF_PCI}/sriov_numvfs"
sleep 1

VF_PCIS=()
for i in 0 1 2 3 4; do
  VF_PCIS+=("$(vf_pci_addr "${i}")")
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" mac "${VF_MACS[$i]}" vlan "${VF_VLANS[$i]}" spoofchk off
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" trust on 2>/dev/null || true
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" state enable 2>/dev/null || true
  log "VF${i} ${VF_PCIS[$i]} mac=${VF_MACS[$i]} vlan=${VF_VLANS[$i]}"
done

log "Binding VFs"
for i in 0 1 2 3 4; do
  bind_device "${VF_PCIS[$i]}" "${VF_DRIVERS[$i]}"
done

mkdir -p "$(dirname "${OUT_FILE}")"
run_priv rm -f "${OUT_FILE}"
{
  echo "PF Interface: ${PF_IFACE}"
  echo "PF PCI: ${PF_PCI}"
  echo "VF Assignments:"
  for i in 0 1 2 3 4; do
    printf "  %s: %s MAC=%s VLAN=%s (%s)\n" \
      "${VF_LABELS[$i]}" "${VF_PCIS[$i]}" "${VF_MACS[$i]}" "${VF_VLANS[$i]}" "${VF_DRIVERS[$i]}"
  done
} | tee "${OUT_FILE}"

log "DPDK network status"
run_priv "${DEVBIND}" --status-dev net || true

if [[ "${DPDK_DRIVER}" == "vfio-pci" ]]; then
  check_vfio_group_viability
else
  warn "Using ${DPDK_DRIVER}; skipping VFIO IOMMU group viability check"
fi

log "Network preparation complete"
