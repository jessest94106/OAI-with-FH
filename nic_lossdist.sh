#!/bin/bash
# Measure the REAL NIC VF-pair UDP loss DISTRIBUTION (burst-length structure), not just
# the mean: kernel iavf VF pair through the X710 VEB, our seq-tracking tool reconstructs
# the loss pattern online (no capture -> no capture loss).
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2
NL=/home/jesse/oran_lab/nicloss
cleanup(){ sudo ip netns exec nsB pkill nicloss 2>/dev/null; sudo ip netns del nsA 2>/dev/null; sudo ip netns del nsB 2>/dev/null
  sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF0 $VF2 2>/dev/null; echo "[cleanup done]"; }
trap cleanup EXIT
sudo modprobe iavf 2>/dev/null
sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b iavf $VF0 $VF2; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF0/net/ 2>/dev/null | head -1)
D2=$(ls /sys/bus/pci/devices/$VF2/net/ 2>/dev/null | head -1)
echo "netdevs: vf0=$D0 vf2=$D2"; [[ -z "$D0" || -z "$D2" ]] && { echo "ERR no netdevs"; exit 1; }
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D2" netns nsB
sudo ip netns exec nsA ip addr add 192.168.99.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up; sudo ip netns exec nsA ip link set lo up
sudo ip netns exec nsB ip addr add 192.168.99.2/24 dev "$D2"; sudo ip netns exec nsB ip link set "$D2" up; sudo ip netns exec nsB ip link set lo up
sleep 3
sudo ip netns exec nsA ping -c 3 -W 1 192.168.99.2 >/dev/null 2>&1 && echo "VEB link OK" || { echo "VEB link FAIL"; exit 1; }
for RATE in 0 3300 3000 2000 1000; do
  echo "===== offered ${RATE} Mbps (0=line-rate blast) ====="
  sudo ip netns exec nsB $NL recv 5001 4 > /tmp/nl_recv_$RATE.txt 2>&1 &
  RPID=$!; sleep 1
  sudo ip netns exec nsA $NL send 192.168.99.2 5001 $RATE 8 2>/dev/null
  wait $RPID 2>/dev/null
  grep -E "^RECV|^SUMMARY" /tmp/nl_recv_$RATE.txt
  echo "  burst histogram:"; awk '/burstlen,count/{f=1;next} /SUMMARY/{f=0} f{print "   ",$0}' /tmp/nl_recv_$RATE.txt | head -12
done
echo "[done] full traces in /tmp/nl_recv_*.txt"
