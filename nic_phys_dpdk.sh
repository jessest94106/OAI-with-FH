#!/bin/bash
# TRUE 10G line-rate FH load/loss over the physical port1<->port2 wire via DPDK poll-mode.
# Generator = port1 VF0 (06:02.0, already uio_pci_generic, VST vlan3) txonly.
# Sink      = a fresh VF on port2 (pvid3, uio_pci_generic) rxonly -> polls, drains at line rate.
# Non-invasive: port1's 5 FH VFs + eno1v4/CN untouched; PFs stay on i40e. port2 VF removed after.
set -u
DPDK=/home/jesse/oran_lab/oaicicd/test_dir/dpdk-stable-20.11.9
TESTPMD=$DPDK/build/app/dpdk-testpmd; DEVBIND="python3 $DPDK/usertools/dpdk-devbind.py"
VF0=0000:06:02.0; P2=enp5s0f1np1; P2VFMAC=00:11:22:33:65:01
SECS=12; PKT=1500; P2VF=""

cleanup(){ echo "--- cleanup ---"
  sudo pkill -INT -f dpdk-testpmd 2>/dev/null; sleep 2; sudo pkill -9 -f dpdk-testpmd 2>/dev/null
  [[ -n "$P2VF" ]] && sudo $DEVBIND -u $P2VF 2>/dev/null
  echo 0 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null 2>&1
  sudo find /dev/hugepages -type f -delete 2>/dev/null
  echo "restored: port2 numvfs=$(cat /sys/class/net/$P2/device/sriov_numvfs 2>/dev/null); port1 VFs=$(ip link show eno1np0|grep -c 'vf ')"; }
trap cleanup EXIT

echo "=== create 1 VF on port2 ($P2), set mac/pvid3, bind to DPDK ==="
echo 0 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null
echo 1 | sudo tee /sys/class/net/$P2/device/sriov_numvfs >/dev/null; sleep 2
P2VF=$(basename $(readlink /sys/class/net/$P2/device/virtfn0))
echo "  port2 VF pci = $P2VF"
sudo ip link set $P2 vf 0 mac $P2VFMAC
sudo ip link set $P2 vf 0 vlan 3
sudo ip link set $P2 vf 0 spoofchk off
sudo ip link set $P2 vf 0 trust on
sudo ip link set $P2 up; sleep 1
sudo modprobe uio_pci_generic 2>/dev/null
sudo $DEVBIND -b uio_pci_generic $P2VF || { echo "VF bind FAILED"; exit 1; }
echo "  bound:"; $DEVBIND -s 2>/dev/null | grep -E "$VF0|$P2VF" | sed 's/^/    /'
ip link show $P2 | grep "vf 0" | sed 's/^/  /'

es(){ sudo ethtool -S $1 2>/dev/null | sed 's/^ *//' | awk -v k="$2:" '$1==k{print $2; exit}'; }
echo; echo "=== RX sink (port2 VF, rxonly) cores 4-6 ==="
sudo timeout -s INT $((SECS+5)) $TESTPMD -l 4,5,6 -n 4 --file-prefix=rx -m 1536 -a $P2VF \
   -- --forward-mode=rxonly --rxq=2 --txq=2 --nb-cores=2 --stats-period 3 >/tmp/dpdk_rx.log 2>&1 &
sleep 4
# snapshot PF HW port counters right before the blast
P1TXU0=$(es eno1np0 port.tx_unicast); P2RXU0=$(es enp5s0f1np1 port.rx_unicast)
P2DISC0=$(es enp5s0f1np1 port.rx_discards); P2CRC0=$(es enp5s0f1np1 rx_crc_errors); P2ERR0=$(es enp5s0f1np1 rx_errors)
echo "=== TX gen (port1 VF0, txonly ${PKT}B -> $P2VFMAC) cores 8-10 for ${SECS}s ==="
sudo timeout -s INT $SECS $TESTPMD -l 8,9,10 -n 4 --file-prefix=tx -m 1536 -a $VF0 \
   -- --forward-mode=txonly --eth-peer=0,$P2VFMAC --txq=2 --rxq=2 --nb-cores=2 --txpkts=$PKT --stats-period 3 >/tmp/dpdk_tx.log 2>&1 &
wait
P1TXU1=$(es eno1np0 port.tx_unicast); P2RXU1=$(es enp5s0f1np1 port.rx_unicast)
P2DISC1=$(es enp5s0f1np1 port.rx_discards); P2CRC1=$(es enp5s0f1np1 rx_crc_errors); P2ERR1=$(es enp5s0f1np1 rx_errors)
WIREPUT=$((P1TXU1-P1TXU0)); WIREGOT=$((P2RXU1-P2RXU0))
echo; echo "  >>> WIRE-level (PF HW counters): port1 PHY tx_unicast=$WIREPUT  ->  port2 PHY rx_unicast=$WIREGOT"
echo "  >>> port2 wire errors: rx_discards=+$((P2DISC1-P2DISC0))  rx_crc_errors=+$((P2CRC1-P2CRC0))  rx_errors=+$((P2ERR1-P2ERR0))"
[[ $WIREPUT -gt 0 ]] && awk "BEGIN{printf \"  >>> wire delivery (PHY tx->rx) = %.4f%%  (anything <100%% with crc=0 = NOT the cable)\n\", $WIREGOT*100.0/$WIREPUT}"

echo; echo "########## RESULTS ##########"
TXP=$(grep -oE "TX-packets: *[0-9]+" /tmp/dpdk_tx.log | tail -1 | grep -oE "[0-9]+")
RXP=$(grep -oE "RX-packets: *[0-9]+" /tmp/dpdk_rx.log | tail -1 | grep -oE "[0-9]+")
RXD=$(grep -oE "RX-dropped: *[0-9]+" /tmp/dpdk_rx.log | tail -1 | grep -oE "[0-9]+")
echo "  TX-packets (VF0 sent)    = ${TXP:-?}"
echo "  RX-packets (port2 recvd) = ${RXP:-?}   RX-dropped=${RXD:-0}"
if [[ -n "${TXP:-}" && -n "${RXP:-}" && "${TXP:-0}" -gt 0 ]]; then
  awk "BEGIN{printf \"  wire delivery = %.3f%%  (loss=%.3f%%)\n\", $RXP*100.0/$TXP, ($TXP-$RXP)*100.0/$TXP}"
  awk "BEGIN{printf \"  TX rate ~ %.2f Gbps   RX rate ~ %.2f Gbps  (@%dB / %ds)\n\", $TXP*$PKT*8/1e9/$SECS, $RXP*$PKT*8/1e9/$SECS, $PKT, $SECS}"
fi
echo; echo "  --- testpmd periodic throughput (last samples) ---"
grep -iE "Tx-pps|Tx-bps" /tmp/dpdk_tx.log | tail -3 | sed 's/^/  TX /'
grep -iE "Rx-pps|Rx-bps" /tmp/dpdk_rx.log | tail -3 | sed 's/^/  RX /'
echo "[done] logs: /tmp/dpdk_tx.log /tmp/dpdk_rx.log"
