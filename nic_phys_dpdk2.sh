#!/bin/bash
# Push the physical wire toward 10G line-rate by DEFEATING VEB flooding amplification.
# Generate from port2's SINGLE VF (its VEB floods to the uplink ONLY -> no amplification),
# sink on port1 VF0. Measure PHY tx/rx unicast (true wire load) + wire errors.
set -u
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
TESTPMD=$DPDK/build/app/dpdk-testpmd; DEVBIND="python3 $DPDK/usertools/dpdk-devbind.py"
SINKVF=0000:06:02.0; SINKMAC=00:11:22:33:64:66   # port1 VF0 = sink (rxonly), its mac
P2=enp5s0f1np1; GENMAC=00:11:22:33:65:01          # port2 VF  = generator (txonly)
SECS=12; PKT=1500; GENVF=""
es(){ sudo ethtool -S $1 2>/dev/null | sed 's/^ *//' | awk -v k="$2:" '$1==k{print $2; exit}'; }
cleanup(){ echo "--- cleanup ---"
  sudo pkill -INT -f dpdk-testpmd 2>/dev/null; sleep 2; sudo pkill -9 -f dpdk-testpmd 2>/dev/null
  [[ -n "$GENVF" ]] && sudo $DEVBIND -u $GENVF 2>/dev/null
  echo 0 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null 2>&1
  sudo find /dev/hugepages -type f -delete 2>/dev/null
  echo "restored: port2 numvfs=$(cat /sys/class/net/$P2/device/sriov_numvfs 2>/dev/null); port1 VFs=$(ip link show eno1np0|grep -c 'vf ')"; }
trap cleanup EXIT

echo "=== create generator VF on port2 (single VF -> no flood amplification) ==="
echo 0 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null
echo 1 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null; sleep 2
GENVF=$(basename $(readlink /sys/class/net/$P2/device/virtfn0))
sudo ip link set $P2 vf 0 mac $GENMAC; sudo ip link set $P2 vf 0 vlan 3
sudo ip link set $P2 vf 0 spoofchk off; sudo ip link set $P2 vf 0 trust on; sudo ip link set $P2 up; sleep 1
sudo modprobe uio_pci_generic 2>/dev/null
sudo $DEVBIND -b uio_pci_generic $GENVF || { echo "gen VF bind FAILED"; exit 1; }
echo "  generator=$GENVF (port2, $GENMAC)   sink=$SINKVF (port1 VF0, $SINKMAC)"

echo; echo "=== SINK rxonly (port1 VF0) cores 4-7 ==="
sudo timeout -s INT $((SECS+5)) $TESTPMD -l 4,5,6,7 -n 4 --file-prefix=rx -m 1536 -a $SINKVF \
   -- --forward-mode=rxonly --rxq=4 --txq=4 --nb-cores=3 --stats-period 3 >/tmp/dpdk2_rx.log 2>&1 &
sleep 4
G_TX0=$(es $P2 port.tx_unicast); S_RX0=$(es eno1np0 port.rx_unicast)
S_DISC0=$(es eno1np0 port.rx_discards); S_CRC0=$(es eno1np0 rx_crc_errors)
echo "=== GEN txonly (port2 VF -> $SINKMAC) cores 8-12, 4 queues, ${SECS}s ==="
sudo timeout -s INT $SECS $TESTPMD -l 8,9,10,11,12 -n 4 --file-prefix=tx -m 1536 -a $GENVF \
   -- --forward-mode=txonly --eth-peer=0,$SINKMAC --txq=4 --rxq=4 --nb-cores=4 --txpkts=$PKT --stats-period 3 >/tmp/dpdk2_tx.log 2>&1 &
wait
G_TX1=$(es $P2 port.tx_unicast); S_RX1=$(es eno1np0 port.rx_unicast)
S_DISC1=$(es eno1np0 port.rx_discards); S_CRC1=$(es eno1np0 rx_crc_errors)
PUT=$((G_TX1-G_TX0)); GOT=$((S_RX1-S_RX0))

echo; echo "########## RESULTS (anti-flood) ##########"
TXP=$(grep -oE "TX-packets: *[0-9]+" /tmp/dpdk2_tx.log | tail -1 | grep -oE "[0-9]+")
RXP=$(grep -oE "RX-packets: *[0-9]+" /tmp/dpdk2_rx.log | tail -1 | grep -oE "[0-9]+")
echo "  WIRE PHY: port2 tx_unicast=$PUT -> port1 rx_unicast=$GOT   crc=+$((S_CRC1-S_CRC0))  rx_discards=+$((S_DISC1-S_DISC0))"
[[ $PUT -gt 0 ]] && awk "BEGIN{printf \"  wire delivery = %.4f%%   wire load = %.2f Gbps  (@%dB / %ds)\n\", $GOT*100.0/$PUT, $PUT*$PKT*8/1e9/$SECS, $PKT, $SECS}"
echo "  testpmd: TX-packets=${TXP:-?}  sink RX-packets=${RXP:-?}"
echo "  --- peak throughput ---"
grep -iE "Tx-bps" /tmp/dpdk2_tx.log | tail -3 | sed 's/^/  TX /'
grep -iE "Rx-bps" /tmp/dpdk2_rx.log | tail -3 | sed 's/^/  RX /'
echo "[done]"
