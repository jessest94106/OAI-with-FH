#!/usr/bin/env bash
# 2-physical-port fronthaul prep: RU on 05:00.0 (eno1np0), DU on 05:00.1 (enp5s0f1np1),
# DAC cable between them. Removes the SR-IOV VFs and binds both PFs to DPDK directly
# (NO VEB in the path). Realtime/hugepage prep from this morning's prepare_network.sh persists.
set -euo pipefail
DEVBIND=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9/usertools/dpdk-devbind.py
PF0=0000:05:00.0
PF1=0000:05:00.1

echo "==> Removing VFs from ${PF0}"
sudo sh -c "echo 0 > /sys/bus/pci/devices/${PF0}/sriov_numvfs" || true
sleep 1
echo "==> Links down"
sudo ip link set eno1np0 down 2>/dev/null || true
sudo ip link set enp5s0f1np1 down 2>/dev/null || true
echo "==> Binding both PFs to uio_pci_generic"
sudo modprobe uio_pci_generic
sudo "$DEVBIND" --unbind "$PF0" "$PF1"
sudo "$DEVBIND" --bind=uio_pci_generic "$PF0" "$PF1"
echo "==> Status"
sudo "$DEVBIND" --status-dev net | sed -n '1,12p'
echo "==> 2-port prep complete: RU=${PF0} (f8:f2:1e:1b:51:20) <-> DU=${PF1} (f8:f2:1e:1b:51:22)"
