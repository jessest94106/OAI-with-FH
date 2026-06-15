#!/bin/bash
# Final confirmation: port.rx_discards is descriptor starvation (host), not the wire.
# Bump RX/TX ring depth to max; if discards fall + delivery rises, loss is host-side.
set -u
P1=eno1np0; P2=enp5s0f1np1; NS=fhtest; NL=/home/jesse/oran_lab/nicloss
IP1=192.168.99.1; IP2=192.168.99.2; T=8
ORX=$(ethtool -g $P1 2>/dev/null | awk '/^Current/{f=1} f&&/RX:/{print $2; exit}')
OTX=$(ethtool -g $P1 2>/dev/null | awk '/^Current/{f=1} f&&/TX:/{print $2; exit}')
cleanup(){ sudo ip netns exec $NS pkill -f nicloss 2>/dev/null; pkill -f nicloss 2>/dev/null
  sudo ip -n $NS link set $P2 netns 1 2>/dev/null; sudo ip addr del $IP1/24 dev $P1 2>/dev/null
  sudo ip netns del $NS 2>/dev/null; sudo ip link set $P2 up 2>/dev/null
  sudo ethtool -G $P1 rx ${ORX:-512} tx ${OTX:-512} 2>/dev/null
  echo "--- restored (rings back to rx=$ORX tx=$OTX); VFs=$(ip link show $P1|grep -c 'vf ') ---"; }
trap cleanup EXIT
echo "current rings on $P1: rx=$ORX tx=$OTX (max: $(ethtool -g $P1|awk '/Pre-set/{f=1} f&&/RX:/{print $2; exit}'))"
sudo ethtool -G $P1 rx 4096 tx 4096 2>/dev/null
sudo ip netns add $NS; sudo ip link set $P2 netns $NS
sudo ethtool -G $P2 rx 4096 tx 4096 2>/dev/null   # P2 still in root here? it's in NS now; set via ns below
sudo ip netns exec $NS ethtool -G $P2 rx 4096 tx 4096 2>/dev/null
sudo ip addr add $IP1/24 dev $P1; sudo ip link set $P1 mtu 9600 up
sudo ip -n $NS link set lo up; sudo ip -n $NS addr add $IP2/24 dev $P2; sudo ip -n $NS link set $P2 mtu 9600 up
sleep 2; sudo ip netns exec $NS ping -c2 -W1 $IP1 >/dev/null 2>&1 || { echo WIREFAIL; exit 1; }
echo "rings now: $P2 rx=$(sudo ip netns exec $NS ethtool -g $P2|awk '/^Current/{f=1} f&&/RX:/{print $2; exit}')"

disc(){ sudo ip netns exec $NS ethtool -S $P2 2>/dev/null | awk -F: '/port.rx_discards/{gsub(/ /,"",$2); print $2}'; }
txpk(){ cat /sys/class/net/$P1/statistics/tx_packets; }
rxpk(){ sudo ip netns exec $NS cat /sys/class/net/$P2/statistics/rx_packets; }

for k in 0 1 2 3; do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/rg_$k.txt 2>&1 & done
sleep 1
D0=$(disc); TX0=$(txpk); RX0=$(rxpk)
for k in 0 1 2 3; do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) 2000 $T 2>/dev/null & done
wait
D1=$(disc); TX1=$(txpk); RX1=$(rxpk)
dlv=0; for k in 0 1 2 3; do r=$(grep -oE "recvd=[0-9]+" /tmp/rg_$k.txt|cut -d= -f2); dlv=$((dlv+${r:-0})); done
echo "########## offered ~8 Gbps WITH rx ring=4096 ##########"
printf "  port1 tx_pkts=%d -> port2 rx_pkts=%d  (wire-level loss=%.2f%%)\n" "$((TX1-TX0))" "$((RX1-RX0))" "$(awk "BEGIN{print ($((TX1-TX0))?($((TX1-TX0))-$((RX1-RX0)))*100.0/$((TX1-TX0)):0)}")"
printf "  socket delivered=%d  | port.rx_discards delta=%d\n" "$dlv" "$((D1-D0))"
echo "  (compare to rx ring=512 run: ~37%% wire-delta, 7.8M discards)"
echo "[done]"
