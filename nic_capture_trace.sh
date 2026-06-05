#!/bin/bash
# Capture a STATIONARY FH drop-trace at a chosen total offered load, the RIGHT way:
# push the VEB to saturation with N parallel flows (each well under the single-thread
# receiver cap ~4.7Gbps, so NO receiver-overload artifact) and trace ONE flow -> that
# flow sees the real steady-state VEB tail-drop process (burst structure + loss rate).
# Single-flow capture at >4.7Gbps is contaminated by recv scheduling -> bursty artifact.
#   ./nic_capture_trace.sh <total_offered_Mbps> <out.bin> [dur_s]
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss
TOTAL=${1:?total_Mbps}; OUT=${2:?out.bin}; DUR=${3:-15}; N=4
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
per=$((TOTAL/N))
echo "[capture] total=${TOTAL}Mbps N=$N per=${per}Mbps dur=${DUR}s -> trace flow0 -> $OUT"
# receivers: flow 0 writes the trace; others just measure (to confirm per-flow loss matches)
sudo ip netns exec nsB taskset -c 28 $NL recv 5001 4 "$OUT" >/tmp/cap_r0.txt 2>&1 &
for k in 1 2 3; do sudo ip netns exec nsB taskset -c $((28+k)) $NL recv $((5001+k)) 4 >/tmp/cap_r$k.txt 2>&1 & done
sleep 1
for k in 0 1 2 3; do sudo ip netns exec nsA taskset -c $((24+k)) $NL send 192.168.99.2 $((5001+k)) $per $DUR 2>/dev/null & done
wait
recvd=0; sent=0; lost=0
for k in 0 1 2 3; do
  r=$(grep -oE "recvd=[0-9]+" /tmp/cap_r$k.txt|cut -d= -f2); s=$(grep -oE "est_sent=[0-9]+" /tmp/cap_r$k.txt|cut -d= -f2); l=$(grep -oE "lost=[0-9]+" /tmp/cap_r$k.txt|cut -d= -f2)
  recvd=$((recvd+${r:-0})); sent=$((sent+${s:-0})); lost=$((lost+${l:-0}))
done
ach=$(awk "BEGIN{printf \"%.2f\", $recvd*1400*8/1e9/$DUR}")
lp=$(awk "BEGIN{printf \"%.2f\", $sent?100.0*$lost/$sent:0}")
echo "[capture] achieved=${ach}Gbps aggregate_loss=${lp}%  flow0: $(grep -h '^SUMMARY' /tmp/cap_r0.txt)"
ls -la "$OUT" 2>/dev/null
