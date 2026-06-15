#!/bin/bash
# Ta4-window falsification test: 3x 273-PRB iq9, IDENTICAL to today's failing canary
# except du conf Ta4 (400,440) -> (100,1760). Theory: bad-launch face = RU PRACH U-plane
# (sent late after 12x4096-DFT extraction) lands beyond Ta4_max=440us at the DU's xran RX
# -> silently dropped -> gNB PRACH 0.0 dB forever. Widening the window should kill the face
# on today's bad box WITHOUT any rebuild. PUSCH unaffected (always in-window).
set -u
BASE=/home/jesse/oran_lab
BW=273
ADV=65536
N=3
OUTROOT="$BASE/logs/ta4_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTROOT"
echo "[ta4] OUTROOT=$OUTROOT  N=$N  273-PRB iq9  Ta4 (400,440)->(100,1760)"

preflight() {
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
  # THE ONE CHANGE vs the failing canary:
  sed -i 's/Ta4       = (400, 440)/Ta4       = (100, 1760)/' "$BASE/du_test.conf"
  grep -n 'Ta4' "$BASE/du_test.conf" | sed 's/^/[ta4][CONF] /'
  for s in $(seq 1 12); do l=$(awk '{print $1}' /proc/loadavg); awk "BEGIN{exit !($l<2.0)}" && break; sleep 10; done
}

k=0
for i in $(seq 1 $N); do
  echo "[ta4] ===== trial $i/$N ====="
  preflight
  OD="$OUTROOT/t${i}_$(date +%H%M%S)"
  CHANMOD=0 NB_ANT=1 BW_PRB=$BW XRAN_TIMESCALE=0.25 VRTSIM_TIMESCALE=0.25 VRTSIM_TX_ADVANCE=$ADV \
    WIDTHS="9" IPERF_DIRECTION=ul IPERF_UDP=1 IPERF_UDP_RATE=80M \
    RU_WAIT_SECONDS=60 DU_WAIT_SECONDS=240 UE_WAIT_SECONDS=300 \
    bash "$BASE/sweep_iq_width.sh" --out-dir "$OD" 2>&1 | tail -2
  row=$(tail -1 "$OD/summary.csv" 2>/dev/null)
  st=$(echo "$row" | awk -F, '{print $5}'); ul=$(echo "$row" | awk -F, '{print $26}')
  nz=$(grep -ac 'non_zero_compressed=[1-9]' "$OD/iq9/du.log" 2>/dev/null)
  raproc=$(grep -a 'RAPROC' "$OD/iq9/du.log" 2>/dev/null | grep -acv 'energy 0.0 dB')
  echo "[ta4][RESULT] trial $i: st=$st ul=$ul du_nonzero_prach_rx=$nz raproc_nonzero=$raproc"
  [ "$st" = "ok" ] && k=$((k+1))
done
echo "[ta4][RESULT] TOTAL: $k/$N attached (today's baseline without fix: 0/2)"
echo "[ta4] ALL DONE"
