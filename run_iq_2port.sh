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
  sed -i "s/^\(\s*min_grant_prb\s*=\s*\)[0-9]\+/\1${MIN_GRANT_PRB:-$BW}/" "$BASE/du_test.conf"
  # UL-throughput fix #2 (the CCE-starvation fix): the default UESS has candidates ONLY at
  # AL2 (n2). For a single UE, its DL DCI (scheduled first) and UL DCI share rnti/SS/Y ->
  # same 2 candidate CCEs; the DL DCI wins the slot and the UL DCI collides -> ul_cce_fail
  # (5948 vs DL 10), which starves UL scheduling AND knocks the UL BLER-OLLA down
  # (num_sched<=3 windows) so UL MCS sticks at 17. More candidates -> DL+UL both fit.
  # NOTE: uess_agg_levels is a gNBs-section param (GNBParamList) -> must anchor in the gNBs
  # block (after pusch_AntennaPorts), NOT MACRLCs, or libconfig silently drops it.
  # Element i = #candidates at AL(2^i): [L1,L2,L4,L8,L16].
  [ -n "${UESS_AGG:-}" ] && sed -i "/pusch_AntennaPorts/a\\    uess_agg_levels = [${UESS_AGG}];" "$BASE/du_test.conf"
  # UL-throughput fix #5 (the MCS-cap fix): nr_ue_max_mcs_min_rb (gNB_scheduler_ulsch.c:1714)
  # caps UL MCS so tx_power=compute_ph_factor <= ph. tx_power = bw_factor(=10log10(Rb*2^mu)
  # =27.4 dB @273RB) + delta_tf. delta_tf is only added when use_deltaMCS is on, and it
  # explodes with MCS (~20 dB @MCS28) -> demands ph~48 dB (> PHR range) -> MCS28 unreachable
  # at full band. deltaMCS power-boost is FICTIONAL under vrtsim AGC (RX SNR pinned 38.5 dB
  # regardless of tx power). Turning it off -> tx_power=bw_factor only -> a modest ph clears
  # it and OLLA climbs to 28. (Line 2240 writes any reduction back into the OLLA state.)
  [ -n "${USE_DELTAMCS:-}" ] && sed -i "/pusch_AntennaPorts/a\\    use_deltaMCS = ${USE_DELTAMCS};" "$BASE/du_test.conf"
  # UL-throughput fix #3 (power headroom): vrtsim pins RX SNR via AGC independent of tx
  # power, so the p0 target only drives PHR bookkeeping. At p0=-100 the UE reports PH 10 dB
  # and the PHR limiter (gNB_scheduler_ulsch.c:2237) caps MCS to fit PCMAX. Lowering
  # p0_NominalWithGrant -> PH +27 dB -> PHR limiter no longer binds (RX SNR still 38.5 dB).
  [ -n "${P0_GRANT:-}" ] && sed -i "s/\(p0_NominalWithGrant\s*=\s*\)-\?[0-9]\+/\1${P0_GRANT}/" "$BASE/du_test.conf"
  # UL-throughput fix #4 (MCS selection): with harq_round_max=4 the UL MCS comes from the
  # BLER-OLLA loop (get_mcs_from_bler), which is suppressed by the UL CCE starvation
  # (num_sched<=3 windows knock MCS down) -> stuck at 17 despite 38.5 dB / BLER 0. Setting
  # ul_harq_round_max=1 switches to the SINR branch (gNB_scheduler_ulsch.c:2090) ->
  # get_mcs_from_SINRx10(38.5 dB) -> MCS28, bypassing the CCE-suppressed OLLA. Clean channel
  # (BLER 0) means the lost HARQ retransmissions are never needed.
  [ -n "${UL_HARQ_RR:-}" ] && sed -i "/ul_bler_target_lower/a\\  ul_harq_round_max = ${UL_HARQ_RR};" "$BASE/du_test.conf"
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
