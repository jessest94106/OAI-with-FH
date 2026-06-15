#!/bin/bash
# 2-PHYSICAL-PORT IQ runner: RU VF on port0 (06:02.0 @ eno1np0/05:00.0, MAC 64:66),
# DU VF on port1 (06:0a.0 @ enp5s0f1np1/05:00.1, MAC 64:68), DAC between ports.
# Every FH packet crosses the real wire (no same-PF VEB short-circuit).
# one_vf_cu_plane mode: 1 dpdk device per side carries C+U (oran-config.c:535).
# Inherits all proven fixes: Ta4 widened, RA fix, 3 clock anchors, hugepage hygiene.
set -u
BASE=/home/jesse/oran_lab
BW=273
ADV=65536
WIDTHS_SWEEP="${WIDTHS_SWEEP:-9}"
TS="${TS:-0.25}"
OUTROOT="$BASE/logs/iq2port_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTROOT"
TABLE="$OUTROOT/sweep_table.csv"
echo "iq_width,status,fh_total_mbps,fh_rx_mbps,fh_tx_mbps,fh_late_total,fh_lead_mean,fh_lead_min,ul_mbps,ul_loss_pct,ul_jitter_ms,snr_db_avg,ul_sym_present_pct" > "$TABLE"
echo "[iq2p] OUTROOT=$OUTROOT widths=[$WIDTHS_SWEEP] BW=$BW UL=80M-UDP ts=$TS FABRIC=2port"

preflight() {
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-oru 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2
  sudo find /dev/hugepages -type f -delete
  sudo find /dev/shm -maxdepth 1 -name 'vrtsim*' -delete
  sudo rm -f /tmp/vrtsim_connection
  # MAC assert (wedge-A lesson), both PFs, stack-dead only
  sudo ip link set eno1np0 vf 0 mac 00:11:22:33:64:66 spoofchk off 2>/dev/null
  sudo ip link set enp5s0f1np1 vf 0 mac 00:11:22:33:64:68 spoofchk off 2>/dev/null
  sudo ip link set eno1np0 up mtu 9600 2>/dev/null; sudo ip link set enp5s0f1np1 up mtu 9600 2>/dev/null
  cp "$BASE/du_test.conf.preNoBFPprach_bak" "$BASE/du_test.conf"
  cp "$BASE/ru_test.conf.preNoBFPprach_bak" "$BASE/ru_test.conf"
  cp "$BASE/ue_test.conf.good_bak" "$BASE/ue_test.conf"
  rm -f "$BASE/channelmod_sweep.conf"
  sed -i "s/^\(\s*min_grant_prb\s*=\s*\)[0-9]\+/\1$BW/" "$BASE/du_test.conf"
  sed -i 's/\(preambleTransMax\s*=\s*\)7/\19/' "$BASE/du_test.conf"
  sed -i 's/\(prach_dtx_threshold\s*=\s*\)150/\1100/' "$BASE/du_test.conf"
  sed -i 's/Ta4       = (400, 440)/Ta4       = (100, 1760)/' "$BASE/du_test.conf"
  sed -i 's/phy_log_level    = "warn"/phy_log_level    = "info"/' "$BASE/ru_test.conf"
  # === 2-PORT FABRIC REWRITE (one device per side, peer MAC single-entry) ===
  sed -i 's|dpdk_devices = ("0000:06:02.2", "0000:06:02.3")|dpdk_devices = ("0000:06:0a.0")|' "$BASE/du_test.conf"
  sed -i 's|ru_addr      = ("00:11:22:33:64:66", "00:11:22:33:64:67")|ru_addr      = ("00:11:22:33:64:66")|' "$BASE/du_test.conf"
  sed -i 's|dpdk_devices = ("0000:06:02.0", "0000:06:02.1")|dpdk_devices = ("0000:06:02.0")|' "$BASE/ru_test.conf"
  sed -i 's|du_addr      = ("00:11:22:33:64:68", "00:11:22:33:64:69")|du_addr      = ("00:11:22:33:64:68")|' "$BASE/ru_test.conf"
  grep -h 'dpdk_devices\|ru_addr\|du_addr' "$BASE/du_test.conf" "$BASE/ru_test.conf" | sed 's/^/[iq2p][CONF] /'
  for s in $(seq 1 12); do l=$(awk '{print $1}' /proc/loadavg); awk "BEGIN{exit !($l<2.0)}" && break; sleep 10; done
}

for W in $WIDTHS_SWEEP; do
  echo "[iq2p] ===== iq$W (273 PRB, 2-port fabric) ====="
  preflight
  OD="$OUTROOT/iq${W}_$(date +%H%M%S)"
  CHANMOD=0 NB_ANT=1 BW_PRB=$BW XRAN_TIMESCALE=$TS VRTSIM_TIMESCALE=$TS VRTSIM_TX_ADVANCE=$ADV \
    OAI_FH_MAX_QUEUE_NO_JUMP="${OAI_FH_MAX_QUEUE_NO_JUMP:-8}" OAI_FH_SPIN_CAP="${OAI_FH_SPIN_CAP:-2000}" \
    WIDTHS="$W" IPERF_DIRECTION=ul IPERF_UDP=1 IPERF_UDP_RATE=80M \
    RU_WAIT_SECONDS="${RU_WAIT_SECONDS:-60}" DU_WAIT_SECONDS="${DU_WAIT_SECONDS:-240}" UE_WAIT_SECONDS="${UE_WAIT_SECONDS:-300}" \
    bash "$BASE/sweep_iq_width.sh" --out-dir "$OD" 2>&1 | tail -3
  row=$(tail -1 "$OD/summary.csv" 2>/dev/null)
  if [ -n "$row" ]; then
    echo "$row" | awk -F, 'NF>30{print $2","$5","$24","$22","$23","$30","$31","$32","$26","$29","$28","$18","$33}' >> "$TABLE"
    st=$(echo "$row" | awk -F, '{print $5}'); fh=$(echo "$row" | awk -F, '{print $24}'); ul=$(echo "$row" | awk -F, '{print $26}')
    sk=$(grep -ac 'TTI processing delay' "$OD/iq${W}/du.log" 2>/dev/null)
    echo "[iq2p][RESULT] iq$W: status=$st fh_total=${fh}Mbps ul=${ul}Mbps tti_skips=$sk"
  else
    echo "[iq2p][RESULT] iq$W: NO SUMMARY"
  fi
done
echo "[iq2p] ===== TABLE ====="; cat "$TABLE"
echo "[iq2p] ALL DONE ($TABLE)"
