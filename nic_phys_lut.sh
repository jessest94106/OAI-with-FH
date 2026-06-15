#!/bin/bash
# Physical port1->port2 wire: sweep offered load, measure loss / latency / jitter at each point.
# Load = 4 rate-limited nicloss flows port1(root)->port2(netns); concurrent ping port2->port1
# rides the congested path -> latency (avg) + jitter (mdev). Builds the LUT-style table.
set -u
P1=eno1np0; P2=enp5s0f1np1; NS=fhtest; NL=/home/jesse/oran_lab/nicloss
IP1=192.168.99.1; IP2=192.168.99.2; DUR=6; NF=4
cleanup(){ sudo ip netns exec $NS pkill -f nicloss 2>/dev/null; pkill -f nicloss 2>/dev/null
  sudo ip -n $NS link set $P2 netns 1 2>/dev/null; sudo ip addr del $IP1/24 dev $P1 2>/dev/null
  sudo ip netns del $NS 2>/dev/null; sudo ip link set $P2 up 2>/dev/null; echo "--- restored; VFs=$(ip link show $P1|grep -c 'vf ') ---"; }
trap cleanup EXIT
sudo ip netns add $NS; sudo ip link set $P2 netns $NS
sudo ip addr add $IP1/24 dev $P1; sudo ip link set $P1 mtu 9600 up
sudo ip -n $NS link set lo up; sudo ip -n $NS addr add $IP2/24 dev $P2; sudo ip -n $NS link set $P2 mtu 9600 up
sleep 2; sudo ip netns exec $NS ping -c2 -W1 $IP1 >/dev/null 2>&1 || { echo WIREFAIL; exit 1; }

pingstat(){ sudo ip netns exec $NS ping -c 25 -i 0.2 -W 1 $IP1 2>/dev/null | awk -F' = ' '/rtt|round-trip/{split($2,a,"/"); gsub(/ .*/,"",a[4]); print a[1],a[2],a[3],a[4]}'; } # min avg max mdev
printf "\n%8s %10s %8s | %9s %9s %9s %9s\n" "offer" "deliver" "loss%" "lat_min" "lat_avg" "lat_max" "jitter"
printf "%8s %10s %8s | %9s %9s %9s %9s\n" "Mbps" "Mbps" "" "ms" "ms" "ms" "ms(mdev)"
echo "--------------------------------------------------------------------------------"

# idle baseline (no load)
read lmin lavg lmax ljit < <(pingstat)
printf "%8s %10s %8s | %9s %9s %9s %9s\n" "0" "0" "0.000" "$lmin" "$lavg" "$lmax" "$ljit"

for L in 100 500 1000 2000 3000 3500 4000 4500 5000 5500 6000 8000; do
  PF=$((L/NF))
  for k in $(seq 0 $((NF-1))); do sudo ip netns exec $NS taskset -c $((16+k)) $NL recv $((5001+k)) 3 >/tmp/lut_${L}_$k.txt 2>&1 & done
  sleep 1
  for k in $(seq 0 $((NF-1))); do taskset -c $((8+k)) $NL send $IP2 $((5001+k)) $PF $DUR 2>/dev/null & done
  sleep 1
  read lmin lavg lmax ljit < <(pingstat)   # ping rides the load
  wait
  # aggregate loss + delivered across flows
  sl=0; ss=0; rec=0
  for k in $(seq 0 $((NF-1))); do
    line=$(grep '^RECV' /tmp/lut_${L}_$k.txt)
    s=$(echo "$line"|grep -oE "est_sent=[0-9]+"|cut -d= -f2); l=$(echo "$line"|grep -oE "lost=[0-9]+"|cut -d= -f2); r=$(echo "$line"|grep -oE "recvd=[0-9]+"|cut -d= -f2)
    ss=$((ss+${s:-0})); sl=$((sl+${l:-0})); rec=$((rec+${r:-0}))
  done
  loss=$(awk "BEGIN{printf \"%.3f\", $ss?100.0*$sl/$ss:0}")
  dlv=$(awk "BEGIN{printf \"%.0f\", $rec*1400*8/1e6/$DUR}")
  printf "%8s %10s %8s | %9s %9s %9s %9s\n" "$L" "$dlv" "$loss" "${lmin:-?}" "${lavg:-?}" "${lmax:-?}" "${ljit:-?}"
done
echo "--------------------------------------------------------------------------------"
echo "(load = port1->port2, 4 flows; ping = port2->port1 under load. jitter=ping mdev.)"
echo "[done]"
