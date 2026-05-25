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
GNB_CORE_IFACE="${GNB_CORE_IFACE:-enp7s0}"
GNB_CORE_ADDR="${GNB_CORE_ADDR:-172.21.19.111/16}"
HOUSEKEEPING_CPUS="${HOUSEKEEPING_CPUS:-0-3}"
VF_SETTLE_TIMEOUT="${VF_SETTLE_TIMEOUT:-45}"
VF_POST_SETTLE_SLEEP="${VF_POST_SETTLE_SLEEP:-10}"

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

write_procfs() {
  local value="$1"
  local path="$2"
  printf "%s" "${value}" | run_priv tee "${path}" >/dev/null
}

configure_irq_affinity() {
  local irq affinity_path

  log "Pinning IRQs to housekeeping CPUs ${HOUSEKEEPING_CPUS}"
  for affinity_path in /proc/irq/*/smp_affinity_list; do
    [[ -e "${affinity_path}" ]] || continue
    irq="$(basename "$(dirname "${affinity_path}")")"
    [[ "${irq}" =~ ^[0-9]+$ ]] || continue
    write_procfs "${HOUSEKEEPING_CPUS}" "${affinity_path}" 2>/dev/null || true
  done
}

disable_deep_idle_states() {
  local state name

  log "Disabling deep CPU idle states"
  for state in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable; do
    [[ -e "${state}" ]] || continue
    name="$(<"$(dirname "${state}")/name")"
    [[ "${name}" == "POLL" ]] && continue
    write_sysfs 1 "${state}" 2>/dev/null || true
  done
}

configure_realtime_host() {
  log "Disabling RT scheduler throttling"
  run_priv sysctl -qw kernel.sched_rt_runtime_us=-1 || warn "Could not disable RT scheduler throttling"

  if command -v systemctl >/dev/null 2>&1; then
    log "Stopping irqbalance for this boot"
    run_priv systemctl stop irqbalance 2>/dev/null || true
  fi

  configure_irq_affinity
  disable_deep_idle_states
}

ensure_gnb_core_addr() {
  local addr_ip

  [[ -n "${GNB_CORE_ADDR}" ]] || return
  [[ -d "/sys/class/net/${GNB_CORE_IFACE}" ]] || die "gNB core interface not found: ${GNB_CORE_IFACE}"

  addr_ip="${GNB_CORE_ADDR%%/*}"
  run_priv ip link set dev "${GNB_CORE_IFACE}" up
  if ip -4 addr show dev "${GNB_CORE_IFACE}" | grep -Fq "inet ${addr_ip}/"; then
    log "gNB core address ${GNB_CORE_ADDR} already present on ${GNB_CORE_IFACE}"
  else
    log "Adding gNB core address ${GNB_CORE_ADDR} to ${GNB_CORE_IFACE}"
    run_priv ip addr add "${GNB_CORE_ADDR}" dev "${GNB_CORE_IFACE}"
  fi
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

vf_netdev() {
  local pci="$1"
  local net_path

  for net_path in /sys/bus/pci/devices/"${pci}"/net/*; do
    [[ -e "${net_path}" ]] || continue
    basename "${net_path}"
    return 0
  done
  return 1
}

wait_for_kernel_vfs_ready() {
  local deadline missing i pci driver netdev

  log "Waiting for kernel iavf VF initialization"
  deadline=$((SECONDS + VF_SETTLE_TIMEOUT))
  while (( SECONDS < deadline )); do
    missing=()
    for i in 0 1 2 3 4; do
      pci="${VF_PCIS[$i]}"
      driver="$(pci_driver "${pci}")"
      netdev="$(vf_netdev "${pci}" 2>/dev/null || true)"
      if [[ "${driver}" != "iavf" || -z "${netdev}" ]]; then
        missing+=("${pci}:driver=${driver}:net=${netdev:-none}")
      fi
    done

    if (( ${#missing[@]} == 0 )); then
      log "All kernel VFs are ready; waiting ${VF_POST_SETTLE_SLEEP}s for PF/VF reset churn to stop"
      sleep "${VF_POST_SETTLE_SLEEP}"
      return 0
    fi

    sleep 1
  done

  warn "Timed out waiting for kernel VFs to settle: ${missing[*]}"
  return 1
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

log "Setting CPU frequency governor to performance"
run_priv cpupower frequency-set -g performance
configure_realtime_host

ensure_gnb_core_addr

log "Loading drivers"
run_priv modprobe vfio-pci || true
run_priv modprobe uio || true
run_priv modprobe uio_pci_generic || true
run_priv modprobe iavf || true

log "Resetting and creating ${NUM_VFS} VFs"
run_priv ip link set dev "${PF_IFACE}" up
run_priv ip link set dev "${PF_IFACE}" mtu "${MTU}" || warn "Could not set PF MTU ${MTU} on ${PF_IFACE}"
# Suppress kernel-generated IPv6 NS/RA on the fronthaul PF — these are multicast
# frames that leak into DPDK-bound VFs and get parsed as garbage U-plane packets.
run_priv sysctl -qw "net.ipv6.conf.${PF_IFACE}.disable_ipv6=1" || true
write_sysfs 0 "/sys/bus/pci/devices/${PF_PCI}/sriov_numvfs"
sleep 1
write_sysfs "${NUM_VFS}" "/sys/bus/pci/devices/${PF_PCI}/sriov_numvfs"
sleep 1

VF_PCIS=()
for i in 0 1 2 3 4; do
  VF_PCIS+=("$(vf_pci_addr "${i}")")
done

log "Configuring VF MACs, VLANs, trust, and link state"
for i in 0 1 2 3 4; do
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" mac "${VF_MACS[$i]}" vlan "${VF_VLANS[$i]}" spoofchk off
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" trust on 2>/dev/null || true
  run_priv ip link set dev "${PF_IFACE}" vf "${i}" state enable 2>/dev/null || true
  log "VF ${i}: ${VF_PCIS[$i]} mac=${VF_MACS[$i]} vlan=${VF_VLANS[$i]}"
done

log "Settling PF-side VF configuration"
run_priv udevadm settle 2>/dev/null || true
wait_for_kernel_vfs_ready || true

log "Binding DPDK VFs"
for i in 0 1 2 3; do
  bind_device "${VF_PCIS[$i]}" "${VF_DRIVERS[$i]}"
done

log "Binding capture VF"
bind_device "${VF_PCIS[4]}" "${VF_DRIVERS[4]}"

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
