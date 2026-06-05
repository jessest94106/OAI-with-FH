#!/bin/bash
# Can a VF on port0 reach a VF on port1 with NO cable (both ports link-down)?
# If yes -> there's an internal cross-port path (and we can test if it collapses).
# If no  -> cross-port traffic needs the uplink/wire; VFs don't bypass the cable.
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9; DEVBIND="$DPDK/usertools/dpdk-devbind.py"
PF1=enp5s0f1np1
VF_P0=0000:06:02.0
cleanup(){ for ns in nsA nsB; do sudo ip netns del $ns 2>/dev/null; done
  sudo $DEVBIND -u $VF_P0 $VF_P1 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF_P0 2>/dev/null
  echo 0 | sudo tee /sys/class/net/$PF1/device/sriov_numvfs >/dev/null 2>&1; }
trap cleanup EXIT
echo "== create 1 VF on port1 ($PF1) =="
echo 0 | sudo tee /sys/class/net/$PF1/device/sriov_numvfs >/dev/null
echo 1 | sudo tee /sys/class/net/$PF1/device/sriov_numvfs >/dev/null; sleep 2
VF_P1=$(basename $(readlink /sys/class/net/$PF1/device/virtfn0))
echo "  port1 VF = $VF_P1   (port0 VF = $VF_P0)"
sudo modprobe iavf 2>/dev/null
sudo $DEVBIND -u $VF_P0 $VF_P1 2>/dev/null; sudo $DEVBIND -b iavf $VF_P0 $VF_P1; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF_P0/net/ 2>/dev/null|head -1)
D1=$(ls /sys/bus/pci/devices/$VF_P1/net/ 2>/dev/null|head -1)
echo "  netdevs: port0-VF=$D0  port1-VF=$D1"
[[ -z "$D0" || -z "$D1" ]] && { echo "ERR: VF netdev missing"; exit 1; }
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D1" netns nsB
sudo ip netns exec nsA ip addr add 192.168.88.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up
sudo ip netns exec nsB ip addr add 192.168.88.2/24 dev "$D1"; sudo ip netns exec nsB ip link set "$D1" up
sleep 3
echo "  port0-VF carrier=$(sudo ip netns exec nsA cat /sys/class/net/$D0/carrier 2>/dev/null)  port1-VF carrier=$(sudo ip netns exec nsB cat /sys/class/net/$D1/carrier 2>/dev/null)"
echo "== TEST: ping port0-VF -> port1-VF (cross-port, no cable) =="
sudo ip netns exec nsA ping -c 4 -W 1 192.168.88.2 2>&1 | tail -4
echo "== VERDICT =="
sudo ip netns exec nsA ping -c 2 -W 1 192.168.88.2 >/dev/null 2>&1 && echo "  CROSS-PORT WORKS without cable (internal path exists)" || echo "  NO cross-port path without cable (as expected; uplink/wire needed)"