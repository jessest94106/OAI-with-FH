#!/bin/bash
# Multi-UE orchestrator for the 2-port FH vrtsim stack @273 PRB.
# Demonstrates aggregate UL goodput climbing with N concurrent UEs (single-UE caps ~80 sim).
# Each UE: own netns (isolates TUN; vrtsim shm is NOT net-namespaced so signaling still works
# over the radio), distinct vrtsim ue_id, distinct provisioned IMSI (7487/88/89).
# Aggregate UL = sum of per-UE LCID4 RX bytes at the gNB (the true air goodput; the iperf
# server path drops ~95% downstream and under-reports).
set -u
BASE=/home/jesse/oran_lab
BUILD=$BASE/oaicicd/test_dir/openairinterface5g/build
MAC=$BUILD/nrMAC_stats.log
N_UE="${N_UE:-2}"
BW="${BW:-273}"   # carrier PRBs; all derived params (riv/pointA/prach_start/SSB) computed below
TS="${TS:-0.25}"
ADV="${ADV:-65536}"
IPERF_SECONDS="${IPERF_SECONDS:-60}"
ATTACH_WAIT="${ATTACH_WAIT:-120}"
OUT=$BASE/logs/multiue_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
GCSV=$OUT/aggregate_goodput.csv
log(){ echo "[multiue $(date +%H:%M:%S)] $*"; }

cleanup(){
  log "cleanup"
  cp "$MAC" "$OUT/nrMAC_stats_final.log" 2>/dev/null  # snapshot per-UE MAC rows before next run overwrites
  sudo pkill -9 -f nr-uesoftmodem 2>/dev/null
  sudo pkill -9 -f nr-softmodem 2>/dev/null
  sudo pkill -9 -f nr-oru 2>/dev/null  # -f (not -x): stray nr-oru escaping -x leaks ALL hugepages
  sudo pkill -9 iperf3 2>/dev/null
  sudo pkill -9 -f ul_saturate.py 2>/dev/null
  for i in $(seq 0 $((N_UE-1))); do sudo ip netns del ue$i 2>/dev/null; done
}
trap cleanup EXIT

# ---------------- preflight (from run_iq_2port.sh) ----------------
log "preflight (N_UE=$N_UE BW=$BW TS=$TS)"
sudo pkill -9 -f nr-softmodem 2>/dev/null; sudo pkill -9 -f nr-oru 2>/dev/null; sudo pkill -9 -f nr-uesoftmodem 2>/dev/null
sudo pkill -9 -f ul_saturate.py 2>/dev/null; sleep 3
sudo find /dev/hugepages -type f -delete
# BLOCK-3 PERMANENT FIX: a crashed/SIGKILL'd nr-oru leaves 8192 hugepage FILES behind that keep the
# pages reserved -> the next run starves at Free=0 and the RU can't allocate. Deleting files above
# only helps if nothing holds them; shrinking the pool to 0 forces the kernel to RECLAIM all
# freeable huge pages regardless, then regrow. This self-heals every run from any prior leak.
HPFILE=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
HPNOW=$(cat "$HPFILE" 2>/dev/null || echo 8192)
echo 0 | sudo tee "$HPFILE" >/dev/null; sleep 1
echo "${HP_TOTAL:-$HPNOW}" | sudo tee "$HPFILE" >/dev/null; sleep 1
HPFREE=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
log "hugepages reclaimed: Free=$HPFREE"
[ "${HPFREE:-0}" -lt 4096 ] && log "WARN: only $HPFREE hugepages free after reset (leak may persist)"
sudo find /dev/shm -maxdepth 1 -name 'vrtsim*' -delete
# Cat-B weight ring MUST go too. It is not vrtsim*, so it survived every run: the DU's BFW
# emission (oaioran.c catb_bfw_attach) maps it in the first UL slots, reads a PREVIOUS run's
# weights, and attaches BFW to every UL C-plane section including Msg3 -> RA dies, attach 0/2.
# 3a.1 measured "attach 2/2" only because on its first run this file did not exist yet.
sudo rm -f /dev/shm/catb_weights
sudo rm -f /tmp/vrtsim_connection
rm -f /tmp/vrtsim_mu_steer_on
sudo ip link set eno1np0 vf 0 mac 00:11:22:33:64:66 spoofchk off 2>/dev/null
sudo ip link set enp5s0f1np1 vf 0 mac 00:11:22:33:64:68 spoofchk off 2>/dev/null
sudo ip link set eno1np0 up mtu 9600 2>/dev/null; sudo ip link set enp5s0f1np1 up mtu 9600 2>/dev/null
cp "$BASE/du_test.conf.preNoBFPprach_bak" "$BASE/du_test.conf"
cp "$BASE/ru_test.conf.preNoBFPprach_bak" "$BASE/ru_test.conf"
cp "$BASE/ue_test.conf.good_bak" "$BASE/ue_test.conf"
rm -f "$BASE/channelmod_sweep.conf"
# min_grant_prb: floor that keeps MU same-PRB overlap engaged (sub-full grants fall back to
# disjoint FDM splits). 273 = proven full-band MU behavior; costs slot 19 (261 free after
# PRACH). MIN_GRANT_PRB=24/261 for slot-19 experiments — see memory rev-200..205.
# Default to the carrier width, NOT a hard-coded 273: nr_get_Msg3alloc sizes the Msg3 grant as
# max(8, min_grant_prb) and rejects it when rbStart + that > initial UL BWP size, so a
# min_grant_prb larger than BW makes EVERY Msg2 fail ("No space to allocate Msg 3", logged at
# LOG_D so it is invisible) and attach dies with nothing but "exceeded RA window".
sed -i "s/^\(\s*min_grant_prb\s*=\s*\)[0-9]\+/\1${MIN_GRANT_PRB:-$BW}/" "$BASE/du_test.conf"
# Fronthaul IQ width / compression. IQ_WIDTH sets both data and PRACH width on DU *and* RU
# (they must match). COMP_METH: 1 = BFP (default), 0 = no compression (raw 16-bit).
if [ -n "${IQ_WIDTH:-}" ] || [ -n "${COMP_METH:-}" ]; then
  for _c in "$BASE/du_test.conf" "$BASE/ru_test.conf"; do
    [ -n "${IQ_WIDTH:-}" ] && perl -0pi -e 's/(iq_width\s*=\s*)\d+(\s*;)/${1}'"${IQ_WIDTH}"'${2}/g; s/(iq_width_prach\s*=\s*)\d+(\s*;)/${1}'"${IQ_WIDTH}"'${2}/g;' "$_c"
    [ -n "${COMP_METH:-}" ] && perl -0pi -e 's/(compMeth\s*=\s*)\d+(\s*;)/${1}'"${COMP_METH}"'${2}/g; s/(compMeth_prach\s*=\s*)\d+(\s*;)/${1}'"${COMP_METH}"'${2}/g;' "$_c"
  done
fi
# SRS enablement (default off; SRS_WORK_SCOPE.md Phase 0+)
sed -i "s/^\(\s*do_SRS\s*=\s*\)[0-9]/\1${DO_SRS:-0}/" "$BASE/du_test.conf"
# OLLA link-adaptation band (defaults keep the conf's .15/.05); override for goodput experiments
sed -i "s/^\(\s*ul_bler_target_upper\s*=\s*\).*/\1${UL_BLER_UPPER:-.15};/" "$BASE/du_test.conf"
sed -i "s/^\(\s*ul_bler_target_lower\s*=\s*\).*/\1${UL_BLER_LOWER:-.05};/" "$BASE/du_test.conf"
# OLLA MCS floor (lever-1b): stops deep crashes / long climb-backs. Unset = stock (0).
[ -n "${UL_MIN_MCS:-}" ] && sed -i "s/^\(\s*\)#\?\s*ul_min_mcs.*/\1ul_min_mcs = ${UL_MIN_MCS};/" "$BASE/du_test.conf"
sed -i 's/\(preambleTransMax\s*=\s*\)7/\19/' "$BASE/du_test.conf"
sed -i 's/\(prach_dtx_threshold\s*=\s*\)150/\1100/' "$BASE/du_test.conf"
sed -i 's/Ta4       = (400, 440)/Ta4       = (0, 1760)/' "$BASE/du_test.conf"
sed -i 's/phy_log_level    = "warn"/phy_log_level    = "info"/' "$BASE/ru_test.conf"
sed -i 's/hw_log_level     = "warn"/hw_log_level     = "info"/' "$BASE/ru_test.conf"  # see vrtsim steering enable/activate
# mMIMO gNB RX antennas (mMIMO × multi-UE): patch L1 nb_rx after the bak-restore clobbers it.
[ -n "${NB_ANT_RX:-}" ] && sed -i "s/^\(\s*nb_rx\s*=\s*\)[0-9]\+;/\1${NB_ANT_RX};/" "$BASE/du_test.conf" "$BASE/ru_test.conf"
# CRITICAL: the gNB's PUSCH RX antenna count = carrier_config.num_rx_ant = pusch_AntennaPorts
# (config.c:679), NOT nb_rx. Without this the receiver runs nb_rx_ant=1 (rank-1) -> IRC degenerate,
# MU separation impossible, regardless of nb_rx. Patch pusch_AntennaPorts = NB_ANT_RX too.
[ -n "${NB_ANT_RX:-}" ] && sed -i "s/^\(\s*pusch_AntennaPorts\s*=\s*\)[0-9]\+/\1${NB_ANT_RX}/" "$BASE/du_test.conf"
# NB_ANT_TX: gNB/RU DL antenna count (DL eAxC = nb_tx with the asymmetric-eAxC libxran)
[ -n "${NB_ANT_TX:-}" ] && sed -i "s/^\(\s*nb_tx\s*=\s*\)[0-9]\+;/\1${NB_ANT_TX};/" "$BASE/du_test.conf" "$BASE/ru_test.conf"
# PUSCH_TSNR10: gNB UL power-control target (SNRx10). Under vrtsim AGC-pinned SNR the gNB's
# closed-loop PC fights the AGC when targets differ (TPC steps -> slow-EWMA lag -> SNR craters);
# set >= test SNR (e.g. 400) so the UE pegs at PCMAX = conformance-style pinned UL power.
[ -n "${PUSCH_TSNR10:-}" ] && sed -i "s/^\(\s*pusch_TargetSNRx10\s*=\s*\)[0-9]\+;/\1${PUSCH_TSNR10};/" "$BASE/du_test.conf"
# SL_AHEAD: DL scheduling advance (slots). OAI_FH_UL_SLOT_DELAY shifts the WHOLE L1 clock back,
# which delays DL generation in wall-clock and breaks UE sync; raising sl_ahead by the same amount
# restores DL wall-clock timing while the UL still reads later (needed at 8 RX).
[ -n "${SL_AHEAD:-}" ] && sed -i "s/^\(\s*sl_ahead\s*=\s*\)[0-9]\+/\1${SL_AHEAD}/" "$BASE/du_test.conf"
# 2-port fabric rewrite (one device per side)
sed -i 's|dpdk_devices = ("0000:06:02.2", "0000:06:02.3")|dpdk_devices = ("0000:06:0a.0")|' "$BASE/du_test.conf"
sed -i 's|ru_addr      = ("00:11:22:33:64:66", "00:11:22:33:64:67")|ru_addr      = ("00:11:22:33:64:66")|' "$BASE/du_test.conf"
sed -i 's|dpdk_devices = ("0000:06:02.0", "0000:06:02.1")|dpdk_devices = ("0000:06:02.0")|' "$BASE/ru_test.conf"
sed -i 's|du_addr      = ("00:11:22:33:64:68", "00:11:22:33:64:69")|du_addr      = ("00:11:22:33:64:68")|' "$BASE/ru_test.conf"
# Carrier (SSB-centered), from sweep_iq_width.sh. RIV per 38.214 5.1.2.2.2 with RB_start=0:
# L-1 <= floor(275/2)=137 -> 275*(L-1); else -> 275*(275-L+1)+274. Using the wrong branch
# encodes an out-of-range BWP length and the DU dies in encode_SIB_NR (ASN1 INTEGER assert).
if [ $(( BW - 1 )) -le 137 ]; then
  riv=$(( 275 * (BW - 1) ))                     # <=138 PRB branch
else
  riv=$(( 275 * (275 - BW + 1) + 274 ))         # >138 PRB branch
fi
pointa=$(( 669984 - (BW/2)*24 ))
# PRACH frequency position. Default centers it (BW/2-6), which FRAGMENTS the PUSCH band in
# the PRACH slot into two ~130-PRB halves -> that slot can never carry a full-band MU grant.
# PRACH_START=0 (or BW-12) parks it at a band edge, leaving 261 contiguous PRBs. The RU's
# prach_msg1_start is synced to this value below - both sides must match or PRACH reads 0 dB.
prach_start=${PRACH_START:-$(( BW/2 - 6 ))}
UE_SSB=$(( (BW/2 - 10) * 12 ))
perl -0pi -e 's/(\b(?:dl|ul)_carrierBandwidth\s*=\s*)\d+/${1}'"$BW"'/g; s/(initial(?:DL|UL)BWPlocationAndBandwidth\s*=\s*)\d+/${1}'"$riv"'/g; s/(dl_absoluteFrequencyPointA\s*=\s*)\d+/${1}'"$pointa"'/g; s/(prach_msg1_FrequencyStart\s*=\s*)\d+/${1}'"$prach_start"'/g;' "$BASE/du_test.conf"
perl -0pi -e 's/(tx_bw\s*=\s*\[)\s*\d+\s*(\])/${1}'"$BW"'${2}/g; s/(rx_bw\s*=\s*\[)\s*\d+\s*(\])/${1}'"$BW"'${2}/g;' "$BASE/ru_test.conf"
# CRITICAL (sweep line 170): the RU extracts the PRACH slice via its OWN prach_msg1_start. If it
# doesn't match the DU's prach_msg1_FrequencyStart (=prach_start), the gNB sees PRACH energy 0.0 dB
# -> RAR fails -> no attach. This was the multi-UE attach failure.
perl -0pi -e 's/(prach_msg1_start\s*=\s*)\d+/${1}'"$prach_start"'/g;' "$BASE/ru_test.conf"
# CCE-starvation fix (from run_iq_2port.sh): default UESS has candidates ONLY at AL2 (n2),
# so N UEs' DL+UL DCIs collide -> ul_cce_fail -> per-UE UL falls as UEs are added. More
# candidates -> more DCIs fit/slot. gNBs-section param -> anchor after pusch_AntennaPorts.
# Element i = #candidates at AL(2^i): [L1,L2,L4,L8,L16].
[ -n "${UESS_AGG:-}" ] && sed -i "/pusch_AntennaPorts/a\\    uess_agg_levels = [${UESS_AGG}];" "$BASE/du_test.conf"
# UL_MCS_PIN: pin the UL MCS (ul_min_mcs=ul_max_mcs) for controlled A/B at fixed Qm
[ -n "${UL_MCS_PIN:-}" ] && sed -i "/pusch_TargetSNRx10/a\\    ul_max_mcs           = ${UL_MCS_PIN};\n    ul_min_mcs           = ${UL_MCS_PIN};" "$BASE/du_test.conf"
log "273 conf: riv=$riv pointA=$pointa prach_start=$prach_start UE_SSB=$UE_SSB uess_agg=[${UESS_AGG:-default}]"

export XRAN_TIME_EPOCH=$(date +%s)
export XRAN_TIMESCALE=$TS
export VRTSIM_RU_EXTRA_ARGS="--vrtsim.timescale $TS --vrtsim.tx-sample-advance $ADV --vrtsim.num_ues ${RU_NUM_UES:-$N_UE}"
VRTSIM_UE_BASE="--vrtsim.timescale $TS --vrtsim.tx-sample-advance $ADV${VRTSIM_UE_XARGS:+ $VRTSIM_UE_XARGS}"
# CHANMOD=1: no-chanmod multi-UE DL fails (UEs sync to SSB but NACK SIB1 -> never RACH).
# chanmod gives the server per-UE channel descriptors so the DL/UL is properly modelled per UE.
# Emit AWGN passthrough (ploss 0, low noise) + a ue_config listing N 1x1 UEs.
if [ "${CHANMOD:-0}" = "1" ]; then
  CM="$BASE/channelmod_mue_active.conf"
  { echo "channelmod = {"; echo "  max_chan = 10;"; echo "  modellist = \"vrtsim_mue_list\";"; echo "  vrtsim_mue_list = (";
    echo "    { model_name = \"server_tx_channel_model\"; type = \"${CHAN_TYPE:-AWGN}\"; ploss_dB = 0; noise_power_dB = ${CHAN_NOISE:--30}; forgetfact = 0; offset = 0; ds_tdl = $(awk "BEGIN{printf \"%.9g\", ${CHAN_DS_US:-0}*1e-6}"); },";
    echo "    { model_name = \"client_tx_channel_model\"; type = \"${CHAN_TYPE:-AWGN}\"; ploss_dB = 0; noise_power_dB = ${CHAN_NOISE:--30}; forgetfact = 0; offset = 0; ds_tdl = $(awk "BEGIN{printf \"%.9g\", ${CHAN_DS_US:-0}*1e-6}"); }";
    echo "  );"; echo "};"; echo "vrtsim = { ue_config = (";
    for j in $(seq 1 $N_UE); do printf '    { antennas = "1x1"; }%s\n' "$([ $j -lt $N_UE ] && echo ,)"; done
    echo "); };"; } > "$CM"
  # libconfig resolves @include RELATIVE to the including file's dir -> conf must sit next to
  # ru_test.conf/ue_test.conf (both in $BASE), and the per-UE confs must also live in $BASE.
  grep -q 'channelmod_mue_active.conf' "$BASE/ru_test.conf" || printf '\n@include "channelmod_mue_active.conf"\n' >> "$BASE/ru_test.conf"
  grep -q 'channelmod_mue_active.conf' "$BASE/ue_test.conf" || printf '\n@include "channelmod_mue_active.conf"\n' >> "$BASE/ue_test.conf"
  export VRTSIM_RU_EXTRA_ARGS="--vrtsim.chanmod 1 $VRTSIM_RU_EXTRA_ARGS"
  VRTSIM_UE_BASE="--vrtsim.chanmod 1 $VRTSIM_UE_BASE"
  log "CHANMOD ON (AWGN passthrough, ue_config x$N_UE)"
fi
for s in $(seq 1 12); do l=$(awk '{print $1}' /proc/loadavg); awk "BEGIN{exit !($l<2.0)}" && break; sleep 10; done

# ---------------- RU ----------------
export XRAN_TIME_EPOCH=$(date +%s)   # FRESH epoch right before launch (sweep line 863) - stale epoch = clock misalign
log "launching RU (num_ues=$N_UE) epoch=$XRAN_TIME_EPOCH"
setsid bash "$BASE/run_ru.sh" >"$OUT/ru.log" 2>&1 &
for s in $(seq 1 60); do { [ -f /tmp/vrtsim_connection ] && [ -e /dev/shm/vrtsim_channel ] && pgrep -x nr-oru >/dev/null; } && break; sleep 2; done
pgrep -x nr-oru >/dev/null || { log "RU FAILED to come up"; tail -5 "$OUT/ru.log"; exit 1; }
log "RU up (vrtsim ready)"

# ---------------- DU ----------------
log "launching DU"
OAI_FH_MAX_QUEUE_NO_JUMP=8 OAI_FH_SPIN_CAP="${OAI_FH_SPIN_CAP:-2000}" OAI_FH_EXPECT_FRAGS="${OAI_FH_EXPECT_FRAGS:-}" setsid bash "$BASE/run_du.sh" >"$OUT/du.log" 2>&1 &
for s in $(seq 1 120); do { pgrep -x nr-softmodem >/dev/null && grep -qaE 'got sync|Port 1 Link Up' "$OUT/du.log" 2>/dev/null; } && break; sleep 2; done
sleep 8
pgrep -x nr-softmodem >/dev/null || { log "DU FAILED"; tail -8 "$OUT/du.log"; exit 1; }
log "DU up (FH flowing)"

# ---------------- UEs: SEQUENTIAL attach ----------------
# Attach each UE fully (TUN/PDU) BEFORE launching the next. The no-chanmod UL combine sums all
# N UE UL streams; an un-synced UE pumps garbage into the shared UL and corrupts an attaching
# UE's larger PUSCH (PDU-session request) -> SMF never sees it. Bringing UEs up one at a time
# keeps the not-yet-launched slots silent so each UE attaches against a clean UL.
UE_CORES_ARR=("20,21,28,29" "22,23,30,31" "24,25" "26,27")
declare -a UE_IP
PER_UE_WAIT="${PER_UE_WAIT:-100}"
for i in $(seq 0 $((N_UE-1))); do
  imsi=$((7487 + i)); IMSI="208990000${imsi}"
  conf=$BASE/ue_test_run$i.conf; cp "$BASE/ue_test.conf" "$conf"   # in $BASE so the relative @include resolves
  sed -i "s/imsi *= *\"[0-9]*\"/imsi = \"$IMSI\"/" "$conf"
  if [ "${NO_NETNS:-0}" = "1" ]; then NS=""; else
    sudo ip netns del ue$i 2>/dev/null; sudo ip netns add ue$i; sudo ip netns exec ue$i ip link set lo up 2>/dev/null; NS=ue$i
  fi
  log "launching UE$i ue_id=$i imsi=$IMSI netns=${NS:-<default>} cores=${UE_CORES_ARR[$i]}"
  UE_NETNS=$NS UE_CONF="$conf" UE_CORES="${UE_CORES_ARR[$i]}" RUN_UE_RB=$BW RUN_UE_SSB=$UE_SSB \
    VRTSIM_UE_EXTRA_ARGS="$VRTSIM_UE_BASE --vrtsim.ue_id $i" \
    OAI_UE_FORCE_SCID="${MU_UE_FORCE:+$((i % 2))}" \
    OAI_UE_FORCE_DMRS_PORT="$( # match the gNB's per-UE port assignment (OAI_UL_MU_PORTS stage); MU_PORT_LIST="0,2" overrides for CDM-group separation
      if [ -n "${MU_PORT_LIST:-}" ]; then echo "$MU_PORT_LIST" | cut -d, -f$((i+1));
      elif [ -n "${OAI_UL_MU_PORTS:-}" ] || [ -n "${MU_UE_FORCE:-}" ]; then echo $((i % 2)); fi)" \
    setsid bash "$BASE/run_ue.sh" >"$OUT/ue$i.log" 2>&1 &
  for s in $(seq 1 $((PER_UE_WAIT/5))); do
    if grep -qaE 'TUN Interface .*successfully configured|PDU Session Establishment Accept' "$OUT/ue$i.log" 2>/dev/null; then
      UE_IP[$i]=$(sudo ip netns exec ue$i ip -o -4 addr show 2>/dev/null | awk '/oaitun/{sub(/\/.*/,"",$4);print $4;exit}')
      log "  UE$i ATTACHED ip=${UE_IP[$i]}"; break
    fi
    pgrep -x nr-softmodem >/dev/null 2>&1 || { log "  DU died during UE$i attach"; break; }
    sleep 5
  done
  [ -z "${UE_IP[$i]:-}" ] && log "  UE$i did NOT attach in ${PER_UE_WAIT}s (continuing)"
done
ok=0; for i in $(seq 0 $((N_UE-1))); do [ -n "${UE_IP[$i]:-}" ] && ok=$((ok+1)); done
log "=== SEQUENTIAL ATTACH RESULT: $ok/$N_UE  ips=[${UE_IP[*]:-}] ==="
# MU steering attach-first trigger: only NOW that all UEs are connected does the RU switch on the
# per-UE steering signatures for the same-PRB MU-MIMO phase (steering during attach storms PRACH).
if [ "$ok" = "$N_UE" ]; then touch /tmp/vrtsim_mu_steer_on; log "MU steering trigger SET (all $N_UE attached)"; fi

# DIAG (MU_DATAPATH_DIAG=1): is the UL data path live? route + tun tx counters before/after a probe.
if [ "${MU_DATAPATH_DIAG:-0}" = "1" ]; then
  for i in $(seq 0 $((N_UE-1))); do
    [ -z "${UE_IP[$i]:-}" ] && continue
    tif=$(sudo ip netns exec ue$i sh -c 'ls /sys/class/net | grep -i oaitun | head -1')
    log "UE$i tun=$tif route:"; sudo ip netns exec ue$i ip route 2>&1 | sed 's/^/      /'
    b=$(sudo ip netns exec ue$i cat /sys/class/net/$tif/statistics/tx_packets 2>/dev/null)
    sudo ip netns exec ue$i python3 "$BASE/ul_saturate.py" 10.0.0.1 3 20 >/dev/null 2>&1
    a=$(sudo ip netns exec ue$i cat /sys/class/net/$tif/statistics/tx_packets 2>/dev/null)
    log "UE$i $tif tx_packets: before=$b after=$a (delta=$((a-b)) => packets that reached the tun)"
  done
fi

# ---------------- sustained simultaneous UL load (server-less) + gNB-side goodput sampler ----------------
# iperf3 -u needs a TCP control channel to a reachable UPF; when that path is flaky the client dies
# with a 0-byte log and NO UL traffic -> the UEs never co-schedule. Use a server-less UDP saturator
# (ul_saturate.py) that just backlogs the UE RLC buffer -> continuous grants -> two backlogged UEs
# land on the same PRBs. UL_RATE_MBPS above the per-UE UL ceiling keeps both backlogged.
log "starting server-less UDP UL saturation on all attached UEs (rate=${UL_RATE_MBPS:-60}Mbps each)"
for i in $(seq 0 $((N_UE-1))); do
  [ -z "${UE_IP[$i]:-}" ] && { log "  UE$i has no IP -> no traffic"; continue; }
  # UL_PAYLOAD > 1400 needs a matching tun MTU (per-packet cost in the UE tun->PDCP path
  # caps the feed ~192 sim-Mbps/UE at 1200B; bigger packets = fewer per-packet trips)
  if [ -n "${UE_TUN_MTU:-}" ]; then
    TUN=$(sudo ip netns exec ue$i ip -o link show 2>/dev/null | awk -F': ' '/oaitun/{print $2; exit}')
    [ -n "$TUN" ] && sudo ip netns exec ue$i ip link set "$TUN" mtu "$UE_TUN_MTU" 2>/dev/null
  fi
  sudo ip netns exec ue$i python3 "$BASE/ul_saturate.py" 10.0.0.1 "$IPERF_SECONDS" "${UL_RATE_MBPS:-60}" "${UL_PAYLOAD:-1200}" >"$OUT/ul_ue$i.log" 2>&1 &
  log "  UE$i UL saturation started (ip=${UE_IP[$i]} payload=${UL_PAYLOAD:-1200})"
done

# aggregate gNB-side goodput: sum LCID4 RX over all UE lines each 4s
echo "epoch sum_lcid4 n_ue_lines mcs_csv" > "$GCSV"
for k in $(seq 1 $((IPERF_SECONDS/4 + 6))); do
  if [ -s "$MAC" ]; then
    now=$(date +%s.%N)
    sumb=$(grep -aE 'LCID 4:' "$MAC" | grep -aoE 'RX[[:space:]]+[0-9]+' | grep -aoE '[0-9]+' | awk '{s+=$1}END{print s+0}')
    nl=$(grep -acE 'LCID 4:' "$MAC")
    mcs=$(grep -aE 'ulsch_rounds' "$MAC" | grep -aoE 'MCS \([0-9]+\) [0-9]+' | grep -aoE '[0-9]+$' | paste -sd, -)
    echo "$now $sumb $nl $mcs" >> "$GCSV"
  fi
  pgrep -x nr-uesoftmodem >/dev/null || break
  sleep 4
done

log "=== iperf clients done; final MAC stats ==="
grep -aE 'UE [0-9a-f]{4}:|in-sync' "$MAC" 2>/dev/null | tail -12 | tee "$OUT/final_mac.txt"
log "=== aggregate goodput series -> $GCSV ==="
cat "$GCSV"
log "DONE. OUT=$OUT"
