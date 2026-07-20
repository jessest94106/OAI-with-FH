#!/bin/bash
# Post-reboot prep for the 2-port FH fabric + CN. Idempotent — run after every reboot.
# Restores what a reboot wipes: VFs/DPDK bind (RU 06:02.0 on eno1np0, DU 06:0a.0 on
# enp5s0f1np1), VF MACs (wedge-A lesson: X710 VEB black-holes on random admin MAC),
# core-net addr on enp7s0, CN docker stack. Kernel cmdline (isolcpus etc.) persists on its own.
set -u
DEVBIND=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9/usertools/dpdk-devbind.py
P0=eno1np0        # PF 05:00.0 -> VF0 = 0000:06:02.0 (RU)
P1=enp5s0f1np1    # PF 05:00.1 -> VF0 = 0000:06:0a.0 (DU)

echo "== NetworkManager hands off both PFs =="
nmcli dev set "$P0" managed no 2>/dev/null; nmcli dev set "$P1" managed no 2>/dev/null

echo "== VFs (1 per PF) =="
for pf in "$P0" "$P1"; do
  cur=$(cat /sys/class/net/$pf/device/sriov_numvfs)
  [ "$cur" = 1 ] || { echo 0 | sudo tee /sys/class/net/$pf/device/sriov_numvfs >/dev/null
                      echo 1 | sudo tee /sys/class/net/$pf/device/sriov_numvfs >/dev/null; sleep 1; }
done
VF0=$(basename "$(readlink /sys/class/net/$P0/device/virtfn0)")
VF1=$(basename "$(readlink /sys/class/net/$P1/device/virtfn0)")
echo "  $P0 VF0=$VF0  $P1 VF0=$VF1"
[ "$VF0" = 0000:06:02.0 ] || echo "  WARN: expected 0000:06:02.0 (confs reference it)"
[ "$VF1" = 0000:06:0a.0 ] || echo "  WARN: expected 0000:06:0a.0 (confs reference it)"

echo "== MACs + link =="
sudo ip link set "$P0" vf 0 mac 00:11:22:33:64:66 spoofchk off
sudo ip link set "$P1" vf 0 mac 00:11:22:33:64:68 spoofchk off
sudo ip link set "$P0" up mtu 9600; sudo ip link set "$P1" up mtu 9600
sudo sysctl -qw net.ipv6.conf.$P0.disable_ipv6=1 net.ipv6.conf.$P1.disable_ipv6=1

echo "== DPDK bind (uio_pci_generic) =="
sudo modprobe uio_pci_generic
sudo "$DEVBIND" --unbind "$VF0" "$VF1" 2>/dev/null
sudo "$DEVBIND" --bind=uio_pci_generic "$VF0" "$VF1"

echo "== core-net addr on enp7s0 =="
sudo ip link set enp7s0 up
ip -4 addr show enp7s0 | grep -q 172.21.19.111 || sudo ip addr add 172.21.19.111/16 dev enp7s0

echo "== CN stack =="
(cd /home/jesse/oran_lab/oai-cn5g && sudo docker-compose up -d) || echo "  WARN: CN start failed"

echo "== verify =="
sudo "$DEVBIND" --status-dev net | grep -E '06:02.0|06:0a.0'
sudo /usr/bin/docker ps --format '{{.Names}} {{.Status}}' | head -12
echo "== prep done =="
