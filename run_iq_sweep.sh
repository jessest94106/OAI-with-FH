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
  sed -i "s/^\(\s*min_grant_prb\s*=\s*\)[0-9]\+/\1$BW/" "$BASE/du_test.conf"
  sed -i 's/\(preambleTransMax\s*=\s*\)7/\19/' "$BASE/du_test.conf"
  sed -i 's/\(prach_dtx_threshold\s*=\s*\)150/\1100/' "$BASE/du_test.conf"
  sed -i 's/phy_log_level    = "warn"/phy_log_level    = "info"/' "$BASE/ru_test.conf"
  # Ta4 FIX (rev-11, PROVEN 3/3 on the 06-12 bad day): stock (400,440)=40us drops the RU's
  # PRACH U-plane (sent late after 12x4096-DFT extraction) at the DU xran RX -> gNB 0.0 dB forever.
  sed -i 's/Ta4       = (400, 440)/Ta4       = (100, 1760)/' "$BASE/du_test.conf"
  for s in $(seq 1 12); do l=$(awk '{print $1}' /proc/loadavg); awk "BEGIN{exit !($l<2.0)}" && break; sleep 10; done
}

for W in $WIDTHS_SWEEP; do
  echo "[iqsweep] ===== iq$W (273 PRB, UL 80M UDP) ====="
  preflight
  OD="$OUTROOT/iq${W}_$(date +%H%M%S)"
  CHANMOD=0 NB_ANT=1 BW_PRB=$BW XRAN_TIMESCALE=0.25 VRTSIM_TIMESCALE=0.25 VRTSIM_TX_ADVANCE=$ADV \
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
