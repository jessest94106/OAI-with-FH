#!/bin/bash
# FH load/loss/latency sweep over the PHYSICAL port1<->port2 wire (SFP-RJ45 + cable),
# the physical-link analogue of nic_lossdist.sh / nic_bidir.sh (which used VF0<->VF2
# through the same-port internal VEB ~6.4 Gbps shared/half-duplex).
# Here port1=eno1np0 (root ns, keep its VFs untouched) <-> port2=enp5s0f1np1 (-> netns)
# so traffic CANNOT short-circuit and MUST traverse the cable. nicloss = UDP seq tool
# (throughput + loss% + burst histogram). Latency added via ping (idle + under load).
set -u
P1=eno1np0; P2=enp5s0f1np1; NS=fhtest
NL=/home/jesse/oran_lab/nicloss; DUR=6
IP1=192.168.99.1; IP2=192.168.99.2

cleanup(){ echo "--- cleanup/restore ---"
  sudo ip netns exec $NS pkill -f nicloss 2>/dev/null; pkill -f "nicloss recv" 2>/dev/null
  sudo ip -n $NS link set $P2 netns 1 2>/dev/null
  sudo ip addr del $IP1/24 dev $P1 2>/dev/null
  sudo ip netns del $NS 2>/dev/null
  sudo ip link set $P2 up 2>/dev/null
  echo "restored: $P2 back in root ns, temp IP off $P1, netns gone; VFs=$(ip link show $P1 2>/dev/null | grep -c 'vf ')"; }
trap cleanup EXIT

# ---- topology: port2 -> netns, port1 stays root (protect its O-RAN VFs) ----
sudo ip netns add $NS
sudo ip link set $P2 netns $NS
sudo ip addr add $IP1/24 dev $P1; sudo ip link set $P1 mtu 9600 up
sudo ip -n $NS link set lo up
sudo ip -n $NS addr add $IP2/24 dev $P2
sudo ip -n $NS link set $P2 mtu 9600 up
sleep 2
sudo ip netns exec $NS ping -c2 -W1 $IP1 >/dev/null 2>&1 || { echo "WIRE FAIL - no link port1<->port2"; exit 1; }
echo "wire up: port1($IP1) <-> port2($IP2) over the cable"

gbps(){ r=$(grep -oE "recvd=[0-9]+" "$1" 2>/dev/null | head -1 | cut -d= -f2); awk "BEGIN{printf \"%.2f\", ${r:-0}*1400*8/1e9/$DUR}"; }
sumf(){ s=0; for f in "$@"; do s=$(awk "BEGIN{print $s+$(gbps "$f")}"); done; echo "$s"; }

echo; echo "########## PHASE 0: idle latency (10GBASE-T PHY baseline) ##########"
sudo ip netns exec $NS ping -c 20 -i 0.2 -W 1 $IP1 | tail -2

echo; echo "########## PHASE A: one-way throughput ceiling, 4 flows port1->port2 ##########"
for k in 0 1 2 3; do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/ps_a_$k.txt 2>&1 & done
sleep 1
for k in 0 1 2 3; do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) 0 $DUR 2>/dev/null & done
wait
echo "  delivered port1->port2 = $(sumf /tmp/ps_a_0.txt /tmp/ps_a_1.txt /tmp/ps_a_2.txt /tmp/ps_a_3.txt) Gbps (4 flows, line-rate blast)"

echo; echo "########## PHASE B: bidirectional (full- vs half-duplex), 4 flows each way ##########"
for k in 0 1 2 3; do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/ps_b_dl_$k.txt 2>&1 & done
for k in 0 1 2 3; do taskset -c $((20+k)) $NL recv $((5101+k)) 3 >/tmp/ps_b_ul_$k.txt 2>&1 & done
sleep 1
for k in 0 1 2 3; do taskset -c $((8+k))  $NL send $IP2 $((5001+k)) 0 $DUR 2>/dev/null & done
for k in 0 1 2 3; do sudo ip netns exec $NS taskset -c $((12+k)) $NL send $IP1 $((5101+k)) 0 $DUR 2>/dev/null & done
wait
DL=$(sumf /tmp/ps_b_dl_0.txt /tmp/ps_b_dl_1.txt /tmp/ps_b_dl_2.txt /tmp/ps_b_dl_3.txt)
UL=$(sumf /tmp/ps_b_ul_0.txt /tmp/ps_b_ul_1.txt /tmp/ps_b_ul_2.txt /tmp/ps_b_ul_3.txt)
echo "  port1->port2 (with reverse) = ${DL} Gbps"
echo "  port2->port1 (with reverse) = ${UL} Gbps"
echo "  sum both dirs               = $(awk "BEGIN{printf \"%.2f\",$DL+$UL}") Gbps"

echo; echo "########## PHASE C: loss vs offered rate, single flow port1->port2 ##########"
for RATE in 1000 2000 3000 4000 5000 6000; do
  sudo ip netns exec $NS taskset -c 16 $NL recv 5001 3 >/tmp/ps_c_$RATE.txt 2>&1 & RPID=$!
  sleep 1
  taskset -c 8 $NL send $IP2 5001 $RATE $DUR 2>/tmp/ps_c_send_$RATE.txt
  wait $RPID 2>/dev/null
  sent=$(grep -oE "[0-9]+ Mbps" /tmp/ps_c_send_$RATE.txt | head -1)
  printf "  offered=%5s Mbps | actual_sent=%-10s | %s\n" "$RATE" "$sent" "$(grep '^RECV' /tmp/ps_c_$RATE.txt)"
done
echo "  burst histogram @ 6000 Mbps:"; awk '/burstlen,count/{f=1;next}/SUMMARY/{f=0}f{print "     ",$0}' /tmp/ps_c_6000.txt | head -8
grep '^SUMMARY' /tmp/ps_c_6000.txt | sed 's/^/     /'

echo; echo "########## PHASE D: latency under load (bufferbloat) ##########"
for k in 0 1 2 3; do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 5 >/dev/null 2>&1 & done
sleep 1
for k in 0 1 2 3; do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) 0 8 2>/dev/null & done
sleep 1
echo "  ping port2->port1 WHILE port1->port2 is saturated:"
sudo ip netns exec $NS ping -c 15 -i 0.2 -W 1 $IP1 | tail -2
wait
echo; echo "[sweep done]"
