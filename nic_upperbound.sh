#!/bin/bash
# Find the FH (VEB) UPPER BOUND: sweep offered load to ~12 Gbps using N parallel
# nicloss flows (each flow's single-thread receiver stays under its ~4.7Gbps cap, so
# NO receiver-overload artifact) -> measure achieved aggregate rate + real loss.
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss; N=4; DUR=6
cleanup(){ sudo ip netns exec nsA pkill nicloss 2>/dev/null; sudo ip netns exec nsB pkill nicloss 2>/dev/null
  sudo ip netns del nsA 2>/dev/null; sudo ip netns del nsB 2>/dev/null
  sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF0 $VF2 2>/dev/null; echo "[cleanup]"; }
trap cleanup EXIT
sudo modprobe iavf 2>/dev/null; sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b iavf $VF0 $VF2; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF0/net/ 2>/dev/null|head -1); D2=$(ls /sys/bus/pci/devices/$VF2/net/ 2>/dev/null|head -1)
[[ -z "$D0" || -z "$D2" ]] && { echo ERR; exit 1; }
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D2" netns nsB
sudo ip netns exec nsA ip addr add 192.168.99.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up; sudo ip netns exec nsA ip link set lo up
sudo ip netns exec nsB ip addr add 192.168.99.2/24 dev "$D2"; sudo ip netns exec nsB ip link set "$D2" up; sudo ip netns exec nsB ip link set lo up
sleep 3
sudo ip netns exec nsA ping -c 2 -W 1 192.168.99.2 >/dev/null 2>&1 && echo "VEB OK ($N flows)" || { echo "VEB FAIL"; exit 1; }
printf "%-12s %-14s %-10s %s\n" "offered_Gbps" "achieved_Gbps" "loss_%" "(per-flow ~singletons/mean_burst at top)"
for TOTAL in 2000 4000 6000 8000 10000 12000 14000 16000; do
  per=$((TOTAL/N))
  for k in $(seq 0 $((N-1))); do sudo ip netns exec nsB taskset -c $((28+k)) $NL recv $((5001+k)) 4 >/tmp/ub_r_$k.txt 2>&1 & done
  sleep 1
  for k in $(seq 0 $((N-1))); do sudo ip netns exec nsA taskset -c $((24+k)) $NL send 192.168.99.2 $((5001+k)) $per $DUR 2>/dev/null & done
  wait
  recvd=0; sent=0; lost=0
  for k in $(seq 0 $((N-1))); do
    r=$(grep -oE "recvd=[0-9]+" /tmp/ub_r_$k.txt|cut -d= -f2); s=$(grep -oE "est_sent=[0-9]+" /tmp/ub_r_$k.txt|cut -d= -f2); l=$(grep -oE "lost=[0-9]+" /tmp/ub_r_$k.txt|cut -d= -f2)
    recvd=$((recvd+${r:-0})); sent=$((sent+${s:-0})); lost=$((lost+${l:-0}))
  done
  ach=$(awk "BEGIN{printf \"%.2f\", $recvd*1400*8/1e9/$DUR}")
  lp=$(awk "BEGIN{printf \"%.2f\", $sent?100.0*$lost/$sent:0}")
  dist=$(grep -h "^SUMMARY" /tmp/ub_r_0.txt | grep -oE "singleton_frac=[0-9.]+ bernoulli_mean_burst=[0-9.]+|mean_burst=[0-9.]+ singleton_frac=[0-9.]+")
  printf "%-12s %-14s %-10s %s\n" "$(awk "BEGIN{printf \"%.1f\",$TOTAL/1000}")" "$ach" "$lp" "$dist"
done
echo "[done] top traces in /tmp/ub_r_*.txt"
