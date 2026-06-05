#!/bin/bash
# Is the VEB internal fabric FULL-duplex (DL & UL each get the full cap) or
# HALF-duplex/shared (DL+UL contend)? Decides the FH-load model: if shared, a
# DL-heavy TDD still saturates the UL path (UL packets are collateral congestion
# loss); if full-duplex, only UL-on-UL contention matters (needs UL-heavy TDD).
# Method: measure VF0->VF2 ALONE, then VF0->VF2 AND VF2->VF0 SIMULTANEOUSLY.
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss; DUR=6
cleanup(){ sudo ip netns exec nsA pkill nicloss 2>/dev/null; sudo ip netns exec nsB pkill nicloss 2>/dev/null
  sudo ip netns del nsA 2>/dev/null; sudo ip netns del nsB 2>/dev/null
  sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF0 $VF2 2>/dev/null; }
trap cleanup EXIT
sudo modprobe iavf 2>/dev/null; sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b iavf $VF0 $VF2; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF0/net/ 2>/dev/null|head -1); D2=$(ls /sys/bus/pci/devices/$VF2/net/ 2>/dev/null|head -1)
[[ -z "$D0" || -z "$D2" ]] && { echo ERR-no-vf; exit 1; }
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D2" netns nsB
sudo ip netns exec nsA ip addr add 192.168.99.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up; sudo ip netns exec nsA ip link set lo up
sudo ip netns exec nsB ip addr add 192.168.99.2/24 dev "$D2"; sudo ip netns exec nsB ip link set "$D2" up; sudo ip netns exec nsB ip link set lo up
sleep 3
sudo ip netns exec nsA ping -c 2 -W 1 192.168.99.2 >/dev/null 2>&1 || { echo VEB-FAIL; exit 1; }
gbps(){ r=$(grep -oE "recvd=[0-9]+" $1|cut -d= -f2); awk "BEGIN{printf \"%.2f\", ${r:-0}*1400*8/1e9/$DUR}"; }

echo "== A) one direction alone (A->B), 4 flows =="
for k in 0 1 2 3; do sudo ip netns exec nsB taskset -c $((28+k)) $NL recv $((5001+k)) 4 >/tmp/bd_ab_$k.txt 2>&1 & done
sleep 1
for k in 0 1 2 3; do sudo ip netns exec nsA taskset -c $((24+k)) $NL send 192.168.99.2 $((5001+k)) 0 $DUR 2>/dev/null & done
wait
ab=0; for k in 0 1 2 3; do ab=$(awk "BEGIN{print $ab+$(gbps /tmp/bd_ab_$k.txt)}"); done
echo "  A->B alone = ${ab} Gbps"

echo "== B) BOTH directions simultaneously, 4 flows each way =="
for k in 0 1 2 3; do sudo ip netns exec nsB taskset -c $((28+k)) $NL recv $((5001+k)) 4 >/tmp/bd2_ab_$k.txt 2>&1 & done
for k in 0 1 2 3; do sudo ip netns exec nsA taskset -c $((20+k)) $NL recv $((5101+k)) 4 >/tmp/bd2_ba_$k.txt 2>&1 & done
sleep 1
for k in 0 1 2 3; do sudo ip netns exec nsA taskset -c $((24+k)) $NL send 192.168.99.2 $((5001+k)) 0 $DUR 2>/dev/null & done
for k in 0 1 2 3; do sudo ip netns exec nsB taskset -c $((16+k)) $NL send 192.168.99.1 $((5101+k)) 0 $DUR 2>/dev/null & done
wait
ab2=0; for k in 0 1 2 3; do ab2=$(awk "BEGIN{print $ab2+$(gbps /tmp/bd2_ab_$k.txt)}"); done
ba2=0; for k in 0 1 2 3; do ba2=$(awk "BEGIN{print $ba2+$(gbps /tmp/bd2_ba_$k.txt)}"); done
echo "  A->B (with reverse) = ${ab2} Gbps"
echo "  B->A (with reverse) = ${ba2} Gbps"
echo "  sum both dirs       = $(awk "BEGIN{printf \"%.2f\",$ab2+$ba2}") Gbps"
echo
echo "VERDICT: if each dir ~= ${ab} (alone) -> FULL-duplex (DL/UL independent)."
echo "         if each dir ~= ${ab}/2 and sum ~= ${ab} -> HALF-duplex/shared (DL saturates UL too)."
