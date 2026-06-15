#!/bin/bash
# Decisive loss attribution on physical port1->port2: is loss on the WIRE/PHY or in the HOST?
# Offer controlled rate (TX not saturated), then compare NIC-level tx_pkts vs rx_pkts and
# socket-level delivery. Wire loss => port2 rx_pkts < port1 tx_pkts (+ rx_crc/rx_errors).
# Host loss => tx_pkts==rx_pkts at NIC but socket got fewer (UDP InErrors/rx_missed).
set -u
P1=eno1np0; P2=enp5s0f1np1; NS=fhtest; NL=/home/jesse/oran_lab/nicloss
IP1=192.168.99.1; IP2=192.168.99.2; T=8
cleanup(){ sudo ip netns exec $NS pkill -f nicloss 2>/dev/null; pkill -f nicloss 2>/dev/null
  sudo ip -n $NS link set $P2 netns 1 2>/dev/null; sudo ip addr del $IP1/24 dev $P1 2>/dev/null
  sudo ip netns del $NS 2>/dev/null; sudo ip link set $P2 up 2>/dev/null; echo "--- restored; VFs=$(ip link show $P1|grep -c 'vf ') ---"; }
trap cleanup EXIT
sudo ip netns add $NS; sudo ip link set $P2 netns $NS
sudo ip addr add $IP1/24 dev $P1; sudo ip link set $P1 mtu 9600 up
sudo ip -n $NS link set lo up; sudo ip -n $NS addr add $IP2/24 dev $P2; sudo ip -n $NS link set $P2 mtu 9600 up
sleep 2; sudo ip netns exec $NS ping -c2 -W1 $IP1 >/dev/null 2>&1 || { echo WIREFAIL; exit 1; }

txpk(){ cat /sys/class/net/$P1/statistics/tx_packets; }
rxpk(){ sudo ip netns exec $NS cat /sys/class/net/$P2/statistics/rx_packets; }
udperr(){ sudo ip netns exec $NS cat /proc/net/snmp | awk '/^Udp:/{u=!u; if(u){for(i=1;i<=NF;i++)h[i]=$i} else {for(i=1;i<=NF;i++) if(h[i]=="InErrors")ie=$i; else if(h[i]=="RcvbufErrors")re=$i}} END{print ie"/"re}'; }

run(){ # $1=nflows $2=per-flow Mbps  -> attribution table
  local NF=$1 RATE=$2
  for k in $(seq 0 $((NF-1))); do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/at_$k.txt 2>&1 & done
  sleep 1
  TX0=$(txpk); RX0=$(rxpk); UE0=$(udperr)
  for k in $(seq 0 $((NF-1))); do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) $RATE $T 2>/dev/null & done
  wait
  TX1=$(txpk); RX1=$(rxpk); UE1=$(udperr)
  local dtx=$((TX1-TX0)) drx=$((RX1-RX0)) dlv=0
  for k in $(seq 0 $((NF-1))); do r=$(grep -oE "recvd=[0-9]+" /tmp/at_$k.txt|cut -d= -f2); dlv=$((dlv+${r:-0})); done
  echo "  offered ~$((NF*RATE)) Mbps ($NF x $RATE):"
  printf "    port1 tx_pkts=%d  ->  port2 rx_pkts=%d  (wire delta=%d, %.3f%%)\n" "$dtx" "$drx" "$((dtx-drx))" "$(awk "BEGIN{print ($dtx? ($dtx-$drx)*100.0/$dtx:0)}")"
  printf "    NIC rx_pkts=%d   ->  socket delivered=%d  (host-drop delta=%d, %.3f%%)\n" "$drx" "$dlv" "$((drx-dlv))" "$(awk "BEGIN{print ($drx? ($drx-$dlv)*100.0/$drx:0)}")"
  echo "    UDP InErrors/RcvbufErrors before=$UE0 after=$UE1"
}

echo "########## attribution @ ~8 Gbps offered (TX unsaturated) ##########"
run 4 2000
echo; echo "  nonzero RX error/drop counters on port2 (CRC=wire, missed=host):"
sudo ip netns exec $NS ethtool -S $P2 2>/dev/null | grep -iE "rx_crc|rx_error|rx_length|rx_missed|rx_dropped|rx_no_dma|rx_discard|port.rx" | grep -vE ":\s*0$" | sed 's/^/     /' || echo "     (all zero)"

echo; echo "########## attribution @ ~12 Gbps offered (overload) ##########"
run 4 3000
echo "[done]"
