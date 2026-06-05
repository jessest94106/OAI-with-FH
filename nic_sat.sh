#!/bin/bash
# Measure the NIC VF-pair loss distribution UNDER SATURATION: blast BOTH directions
# simultaneously so the aggregate exceeds the VEB switch cap (~6.4 Gbps) -> real
# queue-overflow drops -> measure their burst structure (i.i.d. vs bursty/Gilbert-Elliott).
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss
cleanup(){ sudo ip netns exec nsA pkill nicloss 2>/dev/null; sudo ip netns exec nsB pkill nicloss 2>/dev/null
  sudo ip netns del nsA 2>/dev/null; sudo ip netns del nsB 2>/dev/null
  sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF0 $VF2 2>/dev/null; echo "[cleanup]"; }
trap cleanup EXIT
sudo modprobe iavf 2>/dev/null
sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b iavf $VF0 $VF2; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF0/net/ 2>/dev/null | head -1); D2=$(ls /sys/bus/pci/devices/$VF2/net/ 2>/dev/null | head -1)
[[ -z "$D0" || -z "$D2" ]] && { echo ERR; exit 1; }
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D2" netns nsB
sudo ip netns exec nsA ip addr add 192.168.99.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up; sudo ip netns exec nsA ip link set lo up
sudo ip netns exec nsB ip addr add 192.168.99.2/24 dev "$D2"; sudo ip netns exec nsB ip link set "$D2" up; sudo ip netns exec nsB ip link set lo up
sleep 3
sudo ip netns exec nsA ping -c 2 -W 1 192.168.99.2 >/dev/null 2>&1 && echo "VEB OK" || { echo "VEB FAIL"; exit 1; }
echo "===== BIDIRECTIONAL line-rate blast (saturate VEB aggregate) ====="
sudo ip netns exec nsB $NL recv 5001 4 >/tmp/nl_B.txt 2>&1 &
sudo ip netns exec nsA $NL recv 5002 4 >/tmp/nl_A.txt 2>&1 &
sleep 1
sudo ip netns exec nsA $NL send 192.168.99.2 5001 0 8 2>/dev/null &
sudo ip netns exec nsB $NL send 192.168.99.1 5002 0 8 2>/dev/null &
wait
echo "--- dir A->B ---"; grep -E "^RECV|^SUMMARY" /tmp/nl_B.txt; awk '/burstlen,count/{f=1;next}/SUMMARY/{f=0}f{print "   ",$0}' /tmp/nl_B.txt | head -14
echo "--- dir B->A ---"; grep -E "^RECV|^SUMMARY" /tmp/nl_A.txt; awk '/burstlen,count/{f=1;next}/SUMMARY/{f=0}f{print "   ",$0}' /tmp/nl_A.txt | head -14
echo "[done]"
