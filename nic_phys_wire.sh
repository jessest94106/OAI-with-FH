#!/bin/bash
# Separate WIRE capacity from HOST-drain bottleneck on the physical port1<->port2 link.
# (1) blast one-way, read NIC HW byte counters = what the cable actually carried.
# (2) enable RPS to fan RX softirq onto idle isolated cores 4-31, re-measure delivered.
set -u
P1=eno1np0; P2=enp5s0f1np1; NS=fhtest; NL=/home/jesse/oran_lab/nicloss
IP1=192.168.99.1; IP2=192.168.99.2; T=8
cleanup(){ echo "--- cleanup ---"
  sudo ip netns exec $NS pkill -f nicloss 2>/dev/null; pkill -f nicloss 2>/dev/null
  sudo ip -n $NS link set $P2 netns 1 2>/dev/null
  sudo ip addr del $IP1/24 dev $P1 2>/dev/null; sudo ip netns del $NS 2>/dev/null
  sudo ip link set $P2 up 2>/dev/null; echo "restored; VFs=$(ip link show $P1|grep -c 'vf ')"; }
trap cleanup EXIT
sudo ip netns add $NS; sudo ip link set $P2 netns $NS
sudo ip addr add $IP1/24 dev $P1; sudo ip link set $P1 mtu 9600 up
sudo ip -n $NS link set lo up; sudo ip -n $NS addr add $IP2/24 dev $P2; sudo ip -n $NS link set $P2 mtu 9600 up
sleep 2; sudo ip netns exec $NS ping -c2 -W1 $IP1 >/dev/null 2>&1 || { echo WIREFAIL; exit 1; }

rxb(){ sudo ip netns exec $NS cat /sys/class/net/$P2/statistics/rx_bytes; }
txb(){ cat /sys/class/net/$P1/statistics/tx_bytes; }
blast(){ # $1=nflows  -> echoes delivered Gbps from nicloss recvd
  for k in $(seq 0 $(($1-1))); do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/w_$k.txt 2>&1 & done
  sleep 1; R0=$(rxb); X0=$(txb)
  for k in $(seq 0 $(($1-1))); do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) 0 $T 2>/dev/null & done
  wait; R1=$(rxb); X1=$(txb)
  WIRE_RX=$(awk "BEGIN{printf \"%.2f\",($R1-$R0)*8/1e9/$T}")
  WIRE_TX=$(awk "BEGIN{printf \"%.2f\",($X1-$X0)*8/1e9/$T}")
  DLV=0; for k in $(seq 0 $(($1-1))); do r=$(grep -oE "recvd=[0-9]+" /tmp/w_$k.txt|cut -d= -f2); DLV=$(awk "BEGIN{print $DLV+${r:-0}*1400*8/1e9/$T}"); done
  printf "  wire_TX(port1)=%s Gbps  wire_RX(port2)=%s Gbps  socket_delivered=%.2f Gbps\n" "$WIRE_TX" "$WIRE_RX" "$DLV"
}

echo "########## (1) BASELINE: 6-flow one-way blast, IRQs on cpu0-3 ##########"
blast 6
echo "  HW drop counters on RX port2 (host couldn't drain -> these climb):"
sudo ip netns exec $NS ethtool -S $P2 2>/dev/null | grep -iE "rx_missed|rx_dropped|rx_no_dma|port.rx_dropped|rx_oversize" | grep -vE ": 0$" | sed 's/^/     /' || echo "     (none nonzero)"

echo; echo "########## (2) enable RPS -> fan RX softirq onto isolated cores 4-31 ##########"
for q in $(sudo ip netns exec $NS ls /sys/class/net/$P2/queues/ | grep rx-); do
  echo fffffff0 | sudo ip netns exec $NS tee /sys/class/net/$P2/queues/$q/rps_cpus >/dev/null
done
echo 32768 | sudo tee /proc/sys/net/core/rps_sock_flow_entries >/dev/null 2>&1
echo "  RPS set (mask fffffff0 = cpus 4-31) on $(sudo ip netns exec $NS ls /sys/class/net/$P2/queues/ | grep -c rx-) rx queues"
sleep 1
echo "  re-measure 6-flow one-way blast WITH RPS:"
blast 6
echo "[done]"
