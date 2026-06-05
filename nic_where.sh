#!/bin/bash
# Pinpoint the collapse drop stage at offered ~5.7G: sender-VF TX packets (into VEB) vs
# receiver-VF RX packets (out of VEB, into kernel) vs receiver rx_discards (VF RX-ring drop)
# vs app recvd. gap(tx-rx)=VEB-internal drop; rx_discards=RX-ring drop; (rx-app)=socket drop.
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9; DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss; DUR=10; TOTAL=${1:-5700}; N=${2:-6}
cleanup(){ for ns in nsA nsB; do sudo ip netns exec $ns pkill nicloss 2>/dev/null; sudo ip netns del $ns 2>/dev/null; done
  sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b uio_pci_generic $VF0 $VF2 2>/dev/null; }
trap cleanup EXIT
sudo modprobe iavf 2>/dev/null; sudo $DEVBIND -u $VF0 $VF2 2>/dev/null; sudo $DEVBIND -b iavf $VF0 $VF2; sleep 3
D0=$(ls /sys/bus/pci/devices/$VF0/net/|head -1); D2=$(ls /sys/bus/pci/devices/$VF2/net/|head -1)
sudo ip netns add nsA; sudo ip netns add nsB
sudo ip link set "$D0" netns nsA; sudo ip link set "$D2" netns nsB
sudo ip netns exec nsA ip addr add 192.168.99.1/24 dev "$D0"; sudo ip netns exec nsA ip link set "$D0" up
sudo ip netns exec nsB ip addr add 192.168.99.2/24 dev "$D2"; sudo ip netns exec nsB ip link set "$D2" up
sleep 3; sudo ip netns exec nsA ping -c2 -W1 192.168.99.2 >/dev/null 2>&1 || { echo VEB-FAIL; exit 1; }
txpk(){ sudo ip netns exec nsA ip -s link show "$D0" | awk '/TX:/{getline; print $2; exit}'; }
rxpk(){ sudo ip netns exec nsB ip -s link show "$D2" | awk '/RX:/{getline; print $2; exit}'; }
disc(){ sudo ip netns exec nsB ethtool -S "$D2" 2>/dev/null | awk '/rx_discards/{print $2; exit}'; }
per=$((TOTAL/N))
t0=$(txpk); r0=$(rxpk); d0=$(disc)
for k in $(seq 0 $((N-1))); do sudo ip netns exec nsB taskset -c $((16+k)) $NL recv $((5001+k)) 4 >/tmp/w_r$k.txt 2>&1 & done
sleep 1
for k in $(seq 0 $((N-1))); do sudo ip netns exec nsA taskset -c $((1+k)) $NL send 192.168.99.2 $((5001+k)) $per $DUR 2>/dev/null & done
wait
t1=$(txpk); r1=$(rxpk); d1=$(disc)
recvd=0; for k in $(seq 0 $((N-1))); do r=$(grep -oE "recvd=[0-9]+" /tmp/w_r$k.txt|cut -d= -f2); recvd=$((recvd+${r:-0})); done
awk -v tx=$((t1-t0)) -v rx=$((r1-r0)) -v dd=$(( ${d1:-0}-${d0:-0} )) -v app=$recvd -v dur=$DUR -v req=$TOTAL 'BEGIN{
  g=1400*8/1e9/dur;
  printf "offered_req=%d Mbps  DUR=%ds\n",req,dur;
  printf "  sender VF TX packets   = %d  (%.2f Gbps into VEB)\n",tx,tx*g;
  printf "  receiver VF RX packets = %d  (%.2f Gbps out of VEB)\n",rx,rx*g;
  printf "  receiver rx_discards   = %d  (%.2f Gbps RX-ring drop)\n",dd,dd*g;
  printf "  app recvd packets      = %d  (%.2f Gbps to app)\n",app,app*g;
  printf "  --> VEB-internal drop (tx-rx-disc) = %.2f Gbps | RX-ring drop = %.2f Gbps | socket drop (rx-app) = %.2f Gbps\n",(tx-rx-dd)*g,dd*g,(rx-app)*g;
}'