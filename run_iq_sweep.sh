#!/bin/bash
# 273-PRB IQ-width sweep: FH load, FH latency (lead/late), UL throughput per IQ width.
# Each width gets the proven run_snap_validate preflight (which gave 273 = 3/3).
# UL offered at 80M UDP (>~60M expected cap) so iperf_ul reflects real capacity, not the 15M cap.
set -u
BASE=/home/jesse/oran_lab
BW=273
ADV=65536
WIDTHS_SWEEP="${WIDTHS_SWEEP:-8 9 10 12 16}"
OUTROOT="$BASE/logs/iq_sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTROOT"
TABLE="$OUTROOT/sweep_table.csv"
echo "iq_width,status,fh_total_mbps,fh_rx_mbps,fh_tx_mbps,fh_late_total,fh_lead_mean,fh_lead_min,ul_mbps,ul_loss_pct,ul_jitter_ms,snr_db_avg,ul_sym_present_pct" > "$TABLE"
echo "[iqsweep] OUTROOT=$OUTROOT  widths=[$WIDTHS_SWEEP]  BW=$BW UL=80M-UDP ts=0.25"

preflight() {  # identical to the validated run_snap_validate preflight (no MAC code: 273 was 3/3 without it)
  sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-oru 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2
  sudo find /dev/hugepages -type f -delete
  sudo find /dev/shm -maxdepth 1 -name 'vrtsim*' -delete
  sudo rm -f /tmp/vrtsim_connection
  cp "$BASE/du_test.conf.preNoBFPprach_bak" "$BASE/du_test.conf"
  cp "$BASE/ru_test.conf.preNoBFPprach_bak" "$BASE/ru_test.conf"
  cp "$BASE/ue_test.conf.good_bak" "$BASE/ue_test.conf"
  rm -f "$BASE/channelmod_sweep.conf"
  # 2-port fabric (single VF per side: RU 06:02.0 <-> DU 06:0a.0). The .preNoBFPprach_bak confs
  # still list the OLD 2-VF-per-side layout (06:02.1 etc. don't exist -> RU EAL "Cannot find device").
  # Assert VF MACs and rewrite dpdk_devices/addr to the single-device fabric (as run_multi_ue.sh does).
  sudo ip link set eno1np0 vf 0 mac 00:11:22:33:64:66 spoofchk off 2>/dev/null
  sudo ip link set enp5s0f1np1 vf 0 mac 00:11:22:33:64:68 spoofchk off 2>/dev/null
  sudo ip link set eno1np0 up mtu 9600 2>/dev/null; sudo ip link set enp5s0f1np1 up mtu 9600 2>/dev/null
  sed -i 's|dpdk_devices = ("0000:06:02.2", "0000:06:02.3")|dpdk_devices = ("0000:06:0a.0")|' "$BASE/du_test.conf"
  sed -i 's|ru_addr      = ("00:11:22:33:64:66", "00:11:22:33:64:67")|ru_addr      = ("00:11:22:33:64:66")|' "$BASE/du_test.conf"
  sed -i 's|dpdk_devices = ("0000:06:02.0", "0000:06:02.1")|dpdk_devices = ("0000:06:02.0")|' "$BASE/ru_test.conf"
  sed -i 's|du_addr      = ("00:11:22:33:64:68", "00:11:22:33:64:69")|du_addr      = ("00:11:22:33:64:68")|' "$BASE/ru_test.conf"
  sed -i "s/^\(\s*min_grant_prb\s*=\s*\)[0-9]\+/\1$BW/" "$BASE/du_test.conf"
  # gNB L1 RX antennas (mMIMO): the sweep's antenna patch is CHANMOD-gated, so with CHANMOD=0
  # the gNB block stayed nb_rx=1 and the L1 decoded antenna 0 only (no MRC) even though the
  # FH carried NB_ANT_RX streams. Patch the L1 too.
  [ -n "${NB_ANT_RX:-}" ] && sed -i "s/^\(\s*nb_rx\s*=\s*\)[0-9]\+;/\1${NB_ANT_RX};/" "$BASE/du_test.conf"
  # UL MCS via the SINR branch (get_mcs_from_SINRx10) instead of BLER-OLLA — needed for the
  # reported-SNR (ul_cqi) to drive MCS at all (OLLA ignores it). Same knob as run_iq_2port.sh.
  [ -n "${UL_HARQ_RR:-}" ] && sed -i "/ul_bler_target_lower/a\\  ul_harq_round_max = ${UL_HARQ_RR};" "$BASE/du_test.conf"
  sed -i 's/\(preambleTransMax\s*=\s*\)7/\19/' "$BASE/du_test.conf"
  sed -i 's/\(prach_dtx_threshold\s*=\s*\)150/\1100/' "$BASE/du_test.conf"
  sed -i 's/phy_log_level    = "warn"/phy_log_level    = "info"/' "$BASE/ru_test.conf"
  # Ta4 FIX (rev-11, PROVEN 3/3 on the 06-12 bad day): stock (400,440)=40us drops the RU's
  # PRACH U-plane (sent late after 12x4096-DFT extraction) at the DU xran RX -> gNB 0.0 dB forever.
  sed -i 's/Ta4       = (400, 440)/Ta4       = (100, 1760)/' "$BASE/du_test.conf"
  # SU-MIMO 2-layer UL: gNB pusch_AntennaPorts gates maxRank (=min(uecap,ports)).
  [ -n "${PUSCH_ANT_PORTS:-}" ] && sed -i "s/^\(\s*pusch_AntennaPorts\s*=\s*\)[0-9]\+/\1${PUSCH_ANT_PORTS}/" "$BASE/du_test.conf"
  for s in $(seq 1 12); do l=$(awk '{print $1}' /proc/loadavg); awk "BEGIN{exit !($l<2.0)}" && break; sleep 10; done
}

for W in $WIDTHS_SWEEP; do
  echo "[iqsweep] ===== iq$W (273 PRB, UL 80M UDP) ====="
  preflight
  OD="$OUTROOT/iq${W}_$(date +%H%M%S)"
  CHANMOD=${CHANMOD:-0} NB_ANT=${NB_ANT:-1} BW_PRB=$BW XRAN_TIMESCALE=${TS:-0.25} VRTSIM_TIMESCALE=${TS:-0.25} VRTSIM_TX_ADVANCE=$ADV \
    WIDTHS="$W" IPERF_DIRECTION=ul IPERF_UDP=1 IPERF_UDP_RATE=80M \
    RU_WAIT_SECONDS=60 DU_WAIT_SECONDS=240 UE_WAIT_SECONDS=300 \
    bash "$BASE/sweep_iq_width.sh" --out-dir "$OD" 2>&1 | tail -3
  row=$(tail -1 "$OD/summary.csv" 2>/dev/null)
  if [ -n "$row" ]; then
    echo "$row" | awk -F, 'NF>30{print $2","$5","$24","$22","$23","$30","$31","$32","$26","$29","$28","$18","$33}' >> "$TABLE"
    st=$(echo "$row" | awk -F, '{print $5}'); fh=$(echo "$row" | awk -F, '{print $24}'); ul=$(echo "$row" | awk -F, '{print $26}')
    lt=$(echo "$row" | awk -F, '{print $30}'); ld=$(echo "$row" | awk -F, '{print $31}'); ls=$(echo "$row" | awk -F, '{print $29}')
    echo "[iqsweep][RESULT] iq$W: status=$st fh_total=${fh}Mbps ul=${ul}Mbps loss=${ls}% fh_late=$lt fh_lead=$ld"
  else
    echo "[iqsweep][RESULT] iq$W: NO SUMMARY (sweep produced no row)"
  fi
done
echo "[iqsweep] ===== TABLE ====="
cat "$TABLE"
echo "[iqsweep] ALL DONE  ($TABLE)"
