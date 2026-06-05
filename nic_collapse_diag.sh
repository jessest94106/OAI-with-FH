#!/bin/bash
# WHERE do packets vanish at the collapse? Triangulate sender-TX -> VEB-delivered ->
# app-received at a pre-collapse load (4.5G) vs the collapse load (5.7G), using ethtool
# VF counters (what entered/left the fabric) + nicloss app counts + UDP socket-overflow.
#   fabric_drop = senderVF_tx - receiverVF_rx   (lost INSIDE the VEB)
#   socket_drop = receiverVF_rx - app_recvd      (receiver too slow -> kernel drop)
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
DEVBIND="$DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; VF2=0000:06:02.2; NL=/home/jesse/oran_lab/nicloss; DUR=10
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
# pull a numeric counter from ethtool -S, summing any line whose key matches the regex
estat(){ sudo ip netns exec $1 ethtool -S "$2" 2>/dev/null | grep -iE "$3" | grep -oE "[0-9]+$" | awk '{s+=$1}END{print s+0}'; }
udperr(){ sudo ip netns exec $1 awk '/^Udp:/{u++; if(u==2) print $4+$6}' /proc/net/snmp; }  # data-line InErrors+RcvbufErrors
run(){
  local TOTAL=$1 N=$2; local per=$((TOTAL/N))
  local txp0=$(estat nsA "$D0" "tx_(unicast|packets)$"); local rxp0=$(estat nsB "$D2" "rx_(unicast|packets)$")
  local ue0=$(udperr nsB)
  for k in $(seq 0 $((N-1))); do sudo ip netns exec nsB taskset -c $((16+k)) $NL recv $((5001+k)) 4 >/tmp/cd_r$k.txt 2>&1 & done
  sleep 1
  : > /tmp/cd_send.txt
  for k in $(seq 0 $((N-1))); do sudo ip netns exec nsA taskset -c $((1+k)) $NL send 192.168.99.2 $((5001+k)) $per $DUR 2>>/tmp/cd_send.txt & done
  wait
  local txp1=$(estat nsA "$D0" "tx_(unicast|packets)$"); local rxp1=$(estat nsB "$D2" "rx_(unicast|packets)$")
  local ue1=$(udperr nsB)
  local sent_mbps=$(grep -oE "[0-9]+ Mbps" /tmp/cd_send.txt | grep -oE "^[0-9]+" | awk '{s+=$1}END{print s}')
  local recvd=0; for k in $(seq 0 $((N-1))); do r=$(grep -oE "recvd=[0-9]+" /tmp/cd_r$k.txt|cut -d= -f2); recvd=$((recvd+${r:-0})); done
  local txd=$((txp1-txp0)); local rxd=$((rxp1-rxp0)); local ued=$((ue1-ue0))
  awk -v req=$TOTAL -v sent=${sent_mbps:-0} -v tx=$txd -v rx=$rxd -v app=$recvd -v ue=$ued -v dur=$DUR 'BEGIN{
    txg=tx*1400*8/1e9/dur; rxg=rx*1400*8/1e9/dur; appg=app*1400*8/1e9/dur;
    printf "offered_req=%d Mbps | sender_paced=%d Mbps | VF_tx=%.2f Gbps | VF_rx(delivered)=%.2f Gbps | app_recvd=%.2f Gbps\n",req,sent,txg,rxg,appg;
    printf "   -> fabric_drop(tx->rx)=%.2f Gbps (%.0f%%)   socket_drop(rx->app)=%.2f Gbps   udp_overflow_pkts=%d\n",txg-rxg,(txg>0)?100*(txg-rxg)/txg:0,rxg-appg,ue;
  }'
}
echo "== PRE-COLLAPSE (offered ~4.5 Gbps) =="; run 4500 5
echo "== COLLAPSE (offered ~5.7 Gbps) ==";    run 5700 6
echo "== DEEP (offered ~7.0 Gbps) ==";        run 7000 7
