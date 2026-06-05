#!/bin/bash
# Capture STATIONARY FH drop-traces for the 4x4 BW sweep, ONE netns setup.
# Key: hold per-flow rate ~1090 Mbps (well under both the per-flow sender AND the
# single-thread receiver caps) and SCALE the flow count to the target aggregate.
# So every dropped packet is genuine shared-VEB tail-drop, not sender/receiver-local.
# FH offered load(BW) = frame-avg aggregate (DL+UL) U-plane at 4x4 = 40.9 Mbps/PRB.
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss; DUR=15
# PRB -> (offered Mbps, N flows) keeping per-flow ~1090 Mbps
PRBS=(106 133 162 217 273); OFF=(4340 5440 6620 8870 11160); NF=(4 5 6 8 10)
cleanup(){ for ns in nsA nsB; do sudo ip netns exec $ns pkill nicloss 2>/dev/null; sudo ip netns del $ns 2>/dev/null; done
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
printf "%-6s %-8s %-3s %-8s %-8s %-8s %s\n" "PRB" "offered" "N" "per/flow" "achiev" "loss%" "flow0(loss/mean_burst/singleton)"
for i in ${!PRBS[@]}; do
  PRB=${PRBS[$i]}; TOTAL=${OFF[$i]}; N=${NF[$i]}; per=$((TOTAL/N)); OUT=/tmp/fhtrace_P${PRB}.bin
  sudo ip netns exec nsB taskset -c 16 $NL recv 5001 4 "$OUT" >/tmp/cb_r0.txt 2>&1 &
  for k in $(seq 1 $((N-1))); do sudo ip netns exec nsB taskset -c $((16+k)) $NL recv $((5001+k)) 4 >/tmp/cb_r$k.txt 2>&1 & done
  sleep 1
  for k in $(seq 0 $((N-1))); do sudo ip netns exec nsA taskset -c $((1+k)) $NL send 192.168.99.2 $((5001+k)) $per $DUR 2>/dev/null & done
  wait
  recvd=0; sent=0; lost=0
  for k in $(seq 0 $((N-1))); do
    r=$(grep -oE "recvd=[0-9]+" /tmp/cb_r$k.txt|cut -d= -f2); s=$(grep -oE "est_sent=[0-9]+" /tmp/cb_r$k.txt|cut -d= -f2); l=$(grep -oE "lost=[0-9]+" /tmp/cb_r$k.txt|cut -d= -f2)
    recvd=$((recvd+${r:-0})); sent=$((sent+${s:-0})); lost=$((lost+${l:-0}))
  done
  ach=$(awk "BEGIN{printf \"%.2f\", $recvd*1400*8/1e9/$DUR}")
  lp=$(awk "BEGIN{printf \"%.1f\", $sent?100.0*$lost/$sent:0}")
  f0=$(grep -h '^SUMMARY' /tmp/cb_r0.txt | grep -oE "loss_pct=[0-9.]+ .*mean_burst=[0-9.]+ singleton_frac=[0-9.]+")
  printf "%-6s %-8s %-3s %-8s %-8s %-8s %s\n" "$PRB" "$TOTAL" "$N" "$per" "$ach" "$lp" "$f0"
done
echo "[done]"; ls -la /tmp/fhtrace_P*.bin
