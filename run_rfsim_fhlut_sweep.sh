#!/bin/bash
# rfsim + FH-LUT degradation sweep (v4: loss injected at the O-RU->O-DU rxdataF
# boundary = the real FH U-plane; Bernoulli per (symbol x antenna) packet).
# Each point: FH load -> NIC-LUT loss fraction p -> /tmp/fh_inject_loss -> the RU
# drops that fraction of rxdataF U-plane packets -> measure UL throughput + clock
# ratio R (rfsim runs faster than real-time) -> calib_ul = measured/R.
set -u
BASE=/home/jesse/oran_lab
BUILD=$BASE/oai_rfsim_clean/cmake_targets/ran_build/build
GNB_CONF=$BASE/gnb_clean_106.conf; UE_CONF=$BASE/nrue_clean.conf
BW_RB=106; UE_C=3319680000
OFFER="${OFFER:-100M}"; IPERF_T="${IPERF_T:-15}"
GLOG=/tmp/fhlut_gnb.log; ULOG=/tmp/fhlut_ue.log; OUT=/tmp/fhlut_sweep_v4.csv
export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:${BUILD}:${LD_LIBRARY_PATH:-}"
export ASAN_OPTIONS="detect_odr_violation=0"

# load_mbps : FH-loss fraction p  (from NIC LUT /tmp/nic_lat.csv; 0 = OFF)
POINTS=( "0:0" "500:0.0024" "1000:0.015" "1500:0.038" "2000:0.061" "2500:0.0805" "3000:0.10" "3300:0.25" )

attach() {  # clean attach (FH loss OFF); sets UE_IP; retries up to 5x
  UE_IP=""; echo "0" > /tmp/fh_inject_loss; echo "0" > /tmp/fh_inject_us
  for try in 1 2 3 4 5; do
    sudo pkill -9 -x nr-softmodem 2>/dev/null; sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sleep 2
    : > "$GLOG"; : > "$ULOG"
    sudo -E taskset -c 4-15 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
      "$BUILD/nr-softmodem" -O "$GNB_CONF" --rfsim >"$GLOG" 2>&1 &
    for i in $(seq 1 30); do sleep 1; grep -qE "Received NGSetupResponse" "$GLOG" && break; done
    grep -qE "Received NGSetupResponse" "$GLOG" || continue
    sleep 2
    sudo taskset -c 16-27 env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ASAN_OPTIONS="$ASAN_OPTIONS" \
      "$BUILD/nr-uesoftmodem" -O "$UE_CONF" --rfsim -C "$UE_C" -r "$BW_RB" --numerology 1 >"$ULOG" 2>&1 &
    for i in $(seq 1 45); do sleep 1; UE_IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1); [[ -n "$UE_IP" ]] && break; done
    [[ -n "$UE_IP" ]] && return 0
  done
  return 1
}

echo "load_mbps,fh_loss_p,target_loss_pct,ul_rx_mbps,clock_ratio_R,calib_ul_mbps,ul_apploss_pct,idle_rtt_ms,actual_fhdrop_pct" > "$OUT"
UPF_PID=$(docker inspect -f '{{.State.Pid}}' oai-upf 2>/dev/null)

for pt in "${POINTS[@]}"; do
  load=${pt%%:*}; p=${pt##*:}
  tloss=$(awk "BEGIN{printf \"%.2f\", $p*100}")
  if ! attach; then echo "  load=$load p=$p -> ATTACH FAILED"; echo "$load,$p,$tloss,ATTACH_FAIL,,,,," >> "$OUT"; continue; fi
  echo "$p" > /tmp/fh_inject_loss      # turn on FH U-plane loss for this point (fresh RLC)
  sleep 3
  rtt=$(ping -c 5 -i 0.2 -W 1 -I "$UE_IP" 10.0.0.1 2>/dev/null | awk -F'=' '/rtt/{split($2,a,"/"); gsub(/ /,"",a[2]); print a[2]}')
  sudo nsenter -t "$UPF_PID" -n pkill -x iperf3 2>/dev/null; sleep 1
  sudo nsenter -t "$UPF_PID" -n iperf3 -s -B 10.0.0.1 -p 5201 -1 --logfile /tmp/fhlut_srv.log -D; sleep 1
  c1=$(grep -c "stats sfn:" "$ULOG"); t1=$(date +%s.%N)
  timeout $((IPERF_T+15)) iperf3 -c 10.0.0.1 -p 5201 -B "$UE_IP" -u -b "$OFFER" -t "$IPERF_T" >/tmp/fhlut_cli.log 2>&1
  c2=$(grep -c "stats sfn:" "$ULOG"); t2=$(date +%s.%N); sleep 2
  sline=$(grep -E "receiver" /tmp/fhlut_srv.log 2>/dev/null | tail -1)
  rx=$(echo "$sline" | grep -oE '[0-9.]+ [MK]bits/sec' | head -1 | awk '{v=$1; if($2 ~ /K/) v=v/1000; printf "%.1f", v}')
  aloss=$(echo "$sline" | grep -oE '\([0-9.]+%\)' | tr -d '()%' | head -1)
  fhdrop=$(grep "FH-UPLANE-LOSS" "$GLOG" 2>/dev/null | tail -1 | grep -oE '\([0-9.]+%\)' | tr -d '()%')
  R=$(awk "BEGIN{dt=$t2-$t1; fr=($c2-$c1)*128; printf \"%.2f\", (dt>0&&fr>0)?fr/(100*dt):0}")
  cal=$(awk -v rx="${rx:-}" -v R="$R" "BEGIN{ if(rx!=\"\" && R>0) printf \"%.1f\", rx/R; else printf \"\" }")
  echo "  load=${load}Mbps p=${tloss}% -> rx=${rx:-?}Mbps  R=${R}x  CALIB=${cal:-?}Mbps  apploss=${aloss:-?}% rtt=${rtt:-?}ms  actualFHdrop=${fhdrop:-?}%"
  echo "$load,$p,$tloss,${rx:-},${R},${cal},${aloss:-},${rtt:-},${fhdrop:-}" >> "$OUT"
done
echo "0" > /tmp/fh_inject_loss
sudo nsenter -t "$UPF_PID" -n pkill -x iperf3 2>/dev/null
sudo pkill -9 -x nr-uesoftmodem 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null
echo "[done] CSV=$OUT"
