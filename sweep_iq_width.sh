#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR:-${HOME}/oran_lab}"
RU_CONF="${RU_CONF:-${BASE_DIR}/ru_test.conf}"
DU_CONF="${DU_CONF:-${BASE_DIR}/du_test.conf}"
RUN_RU="${RUN_RU:-${BASE_DIR}/run_ru.sh}"
RUN_DU="${RUN_DU:-${BASE_DIR}/run_du.sh}"
RUN_UE="${RUN_UE:-${BASE_DIR}/run_ue.sh}"

WIDTHS="${WIDTHS:-9 16}"
IPERF_SERVER="${IPERF_SERVER:-10.0.0.1}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_SECONDS="${IPERF_SECONDS:-20}"
IPERF_PARALLEL="${IPERF_PARALLEL:-1}"
IPERF_DIRECTION="${IPERF_DIRECTION:-both}" # ul, dl, both, none
# iperf3 server lifecycle. The server lives on IPERF_SERVER (UPF tun0 = 10.0.0.1),
# reachable only over the radio. iperf3 -s is single-threaded, so a stale/duplicate
# server instance causes control-socket resets ("Connection reset by peer") and a
# bogus 0 Mbps. When IPERF_MANAGE_SERVER=1 the sweep guarantees exactly ONE fresh
# server in IPERF_SERVER_NETNS_CONTAINER's network namespace before each test.
IPERF_MANAGE_SERVER="${IPERF_MANAGE_SERVER:-1}"
IPERF_SERVER_NETNS_CONTAINER="${IPERF_SERVER_NETNS_CONTAINER:-oai-upf}"
IPERF_CONNECT_TIMEOUT_MS="${IPERF_CONNECT_TIMEOUT_MS:-5000}"
# UDP mode probes the true radio capacity (no TCP window/RTT limit). IPERF_UDP=1
# uses UDP; IPERF_UDP_RATE is the offered load (0 = unlimited).
IPERF_UDP="${IPERF_UDP:-0}"
IPERF_UDP_RATE="${IPERF_UDP_RATE:-100M}"
# --- FH-latency experiment knobs (channel model + antennas). Default OFF =
# ideal passthrough channel (current behaviour). See FH_LATENCY_EXPERIMENT_FEASIBILITY.md.
CHANMOD="${CHANMOD:-0}"                  # 1 = enable vrtsim channel modelling (chanmod)
CHAN_TYPE="${CHAN_TYPE:-AWGN}"           # AWGN | TDL_A | TDL_B | TDL_C | TDL_D | TDL_E
CHAN_DS_TDL="${CHAN_DS_TDL:-0}"          # delay spread for TDL models, microseconds
CHAN_NOISE_DB="${CHAN_NOISE_DB:--30}"    # channel noise power dB (per-model; NOTE: a NO-OP in vrtsim, kept for record)
CHAN_PLOSS_DB="${CHAN_PLOSS_DB:-0}"      # channel path loss dB
CHAN_RX_SNR_DB="${CHAN_RX_SNR_DB:-}"     # TARGET UL time-domain RX SNR (dB). Set -> vrtsim per-slot AGC injects noise on the UL (UE->RU) to hit this SNR. Empty = off. Needs CHANMOD=1.
CHAN_FORGETFACT="${CHAN_FORGETFACT:-0}"  # 0=static .. ~1=fast-varying. Auto-derived from UE_SPEED_KMH when that is >0 (see build_chanmod).
UE_SPEED_KMH="${UE_SPEED_KMH:-0}"        # UE speed (km/h). >0 converts to max Doppler -> forgetfact (max_Doppler itself is NOT implemented)
CARRIER_HZ="${CARRIER_HZ:-4049760000}"   # carrier freq for the Doppler conversion f_d = (v/3.6)*fc/c (band 77 default in use here)
DOPPLER_HZ=""                            # filled in by build_chanmod when UE_SPEED_KMH>0 (for the report)
VRTSIM_TIMESCALE="${VRTSIM_TIMESCALE:-1.0}" # <1.0 = slower-than-realtime (often needed for chanmod, per vrtsim README)
NB_ANT="${NB_ANT:-1}"                    # gNB+UE antenna count (1..4); raises FH load ~linearly to stress FH latency
BW_PRB="${BW_PRB:-0}"                    # 0=leave conf as-is; else set dl/ul carrierBandwidth + initial BWP RIV + tx_bw/rx_bw. @30kHz SCS: 133=50MHz, 65=25MHz, 24=10MHz
UE_COUNT="${UE_COUNT:-1}"                # documented only: vrtsim multi-UE needs N UE procs + N CN subs + chanmod (see feasibility doc)
# export so the report generator (python subprocess) can show them in ## Radio Context
export CHANMOD CHAN_TYPE CHAN_DS_TDL CHAN_NOISE_DB CHAN_PLOSS_DB CHAN_RX_SNR_DB CHAN_FORGETFACT UE_SPEED_KMH CARRIER_HZ DOPPLER_HZ VRTSIM_TIMESCALE NB_ANT BW_PRB UE_COUNT
RU_WAIT_SECONDS="${RU_WAIT_SECONDS:-30}"
DU_WAIT_SECONDS="${DU_WAIT_SECONDS:-60}"
UE_WAIT_SECONDS="${UE_WAIT_SECONDS:-90}"
UE_START_DELAY_SECONDS="${UE_START_DELAY_SECONDS:-0}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
BETWEEN_TRIAL_SECONDS="${BETWEEN_TRIAL_SECONDS:-5}"
FH_DROP_FIRST="${FH_DROP_FIRST:-2}"
DRY_RUN=0
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${BASE_DIR}/logs/iq_width_sweep/${RUN_ID}}"
CSV="${OUT_DIR}/summary.csv"
REPORT="${OUT_DIR}/report.md"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Runs RU, DU, UE, and iperf3 for each IQ width, then reports FH load and UE throughput.
The script patches ru_test.conf and du_test.conf for each trial and restores them on exit.

Options:
  --widths "9 16"          IQ widths to test. Width 16 uses compMeth=0; others use compMeth=1.
  --iperf-server IP        iperf3 server reachable from UE tunnel. Default: ${IPERF_SERVER}
  --iperf-seconds N        iperf duration per direction. Default: ${IPERF_SECONDS}
  --iperf-direction D      ul, dl, both, or none. Default: ${IPERF_DIRECTION}
  --out-dir DIR            Output directory. Default: ${OUT_DIR}
  --dry-run                Patch/launch plan only; do not start processes.
  -h, --help               Show this help.

Environment overrides are also supported: WIDTHS, IPERF_SERVER, IPERF_SECONDS,
IPERF_DIRECTION, RU_WAIT_SECONDS, DU_WAIT_SECONDS, UE_WAIT_SECONDS,
UE_START_DELAY_SECONDS, SETTLE_SECONDS.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --widths) WIDTHS="$2"; shift 2 ;;
    --iperf-server) IPERF_SERVER="$2"; shift 2 ;;
    --iperf-seconds) IPERF_SECONDS="$2"; shift 2 ;;
    --iperf-direction) IPERF_DIRECTION="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; CSV="${OUT_DIR}/summary.csv"; REPORT="${OUT_DIR}/report.md"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"

UE_CONF="${UE_CONF:-${BASE_DIR}/ue_test.conf}"
RU_BAK="${OUT_DIR}/ru_test.conf.orig"
DU_BAK="${OUT_DIR}/du_test.conf.orig"
UE_BAK="${OUT_DIR}/ue_test.conf.orig"
cp "${RU_CONF}" "${RU_BAK}"
cp "${DU_CONF}" "${DU_BAK}"
[[ -f "${UE_CONF}" ]] && cp "${UE_CONF}" "${UE_BAK}"

RU_PID=""
DU_PID=""
UE_PID=""
STACK_TOUCHED=0
RESTORED=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

restore_configs() {
  if (( RESTORED == 0 )); then
    cp "${RU_BAK}" "${RU_CONF}"
    cp "${DU_BAK}" "${DU_CONF}"
    [[ -f "${UE_BAK}" ]] && cp "${UE_BAK}" "${UE_CONF}"
    RESTORED=1
  fi
}

# When CHANMOD=1, generate a vrtsim channel-model config and wire it into the
# server (RU) + client (UE) via @include, set the vrtsim chanmod/timescale args,
# and set the antenna count. Default (CHANMOD=0) does nothing → behaviour unchanged.
# NOTE: chanmod realtime is fragile (see vrtsim README + FH_LATENCY_EXPERIMENT_FEASIBILITY.md);
# if the UE will not connect, lower VRTSIM_TIMESCALE (e.g. 0.5). NEEDS A VALIDATION RUN.
build_chanmod() {
  # gNB/UE antenna count (FH-load lever). UE side is via run_ue.sh cmdline; gNB/RU
  # side patches the configs. NB_ANT>1 (MIMO) needs validation in this FH/xran setup.
  # Asymmetric antennas: gNB DL TX = NB_ANT_TX, gNB UL RX = NB_ANT_RX (default both = NB_ANT).
  # UE mirrors: UE UL TX = gNB RX, UE DL RX = gNB TX. For a UL-only FH-load test set
  # NB_ANT_TX=1 (cheap DL/attach -> server chanmod ~1 conv, realtime holds) + NB_ANT_RX=4
  # (4x UL FH load + UL MIMO; UE-side UL chanmod already keeps up at 0 drops).
  local nbtx="${NB_ANT_TX:-${NB_ANT}}" nbrx="${NB_ANT_RX:-${NB_ANT}}"
  export UE_NB_ANT_TX="${nbrx}" UE_NB_ANT_RX="${nbtx}"
  if [[ "${nbtx}" != "1" || "${nbrx}" != "1" ]]; then
    perl -0pi -e 's/(\bnb_tx\s*=\s*)\d+/${1}'"${nbtx}"'/g; s/(\bnb_rx\s*=\s*)\d+/${1}'"${nbrx}"'/g;' "${RU_CONF}" "${DU_CONF}"
    perl -0pi -e 's/(pdsch_AntennaPorts_XP\s*=\s*)\d+/${1}'"${nbtx}"'/g; s/(pusch_AntennaPorts\s*=\s*)\d+/${1}'"${nbrx}"'/g; s/(maxMIMO_layers\s*=\s*)\d+/${1}'"${nbtx}"'/g;' "${DU_CONF}"
    log "antennas patched: gNB tx=${nbtx} rx=${nbrx}; UE tx=${nbrx} rx=${nbtx}; pdsch=${nbtx} pusch=${nbrx}"
  fi
  if [[ "${BW_PRB}" != "0" ]]; then
    # Widen the carrier: set dl/ul carrierBandwidth, the initial BWP RIV
    # (locationAndBandwidth for start=0,len=BW_PRB; N_size=275 -> RIV=275*(L-1)),
    # and the RU tx_bw/rx_bw. pointA/SSB are left fixed (SSB stays low-edge valid).
    local riv=$(( 275 * (BW_PRB - 1) ))
    perl -0pi -e 's/(\b(?:dl|ul)_carrierBandwidth\s*=\s*)\d+/${1}'"${BW_PRB}"'/g; s/(initial(?:DL|UL)BWPlocationAndBandwidth\s*=\s*)\d+/${1}'"${riv}"'/g;' "${DU_CONF}"
    perl -0pi -e 's/(tx_bw\s*=\s*\[)\s*\d+\s*(\])/${1}'"${BW_PRB}"'${2}/g; s/(rx_bw\s*=\s*\[)\s*\d+\s*(\])/${1}'"${BW_PRB}"'${2}/g;' "${RU_CONF}"
    export RUN_UE_RB="${BW_PRB}"   # UE cmdline N_RB (-r) must match the carrier
    # pointA is fixed, so the carrier CENTER moves with bandwidth: center = pointA + N_RB*12*SCS/2.
    # pointA here = 4045.44 MHz (ARFCN 669696); SCS=30kHz -> 180kHz/PRB half-step. Update the RU
    # carrier_tx/rx (kHz) and the UE -C (Hz) to the new center, else the UE can't find the SSB.
    local center_hz=$(( 4045440000 + BW_PRB * 180000 )) center_khz=$(( (4045440000 + BW_PRB * 180000) / 1000 ))
    perl -0pi -e 's/(carrier_tx\s*=\s*\[)\s*\d+\s*(\])/${1}'"${center_khz}"'${2}/g; s/(carrier_rx\s*=\s*\[)\s*\d+\s*(\])/${1}'"${center_khz}"'${2}/g;' "${RU_CONF}"
    export RUN_UE_CARRIER="${center_hz}"
    log "bandwidth patched to ${BW_PRB} PRB: carrierBandwidth + BWP RIV=${riv} + tx_bw/rx_bw + UE -r; carrier center -> ${center_hz} Hz (RU carrier_tx/rx + UE -C) — @30kHz: 51=20MHz 133=50MHz"
  fi
  if [[ "${CHANMOD}" != "1" ]]; then
    export VRTSIM_RU_EXTRA_ARGS="" VRTSIM_UE_EXTRA_ARGS=""
    return 0
  fi
  # Convert UE speed (km/h) -> max Doppler (Hz) -> forgetfact. The model does not
  # honor max_Doppler (sim.h), so translate the Doppler into the per-slot channel
  # decorrelation that 'forgetfact' controls: f_d = (v/3.6)*fc/c; coherence time
  # T_c ~= 0.423/f_d (Clarke); forgetfact ~= slot_dur/T_c (clamped 0..1).
  if [[ "${UE_SPEED_KMH}" != "0" ]]; then
    read -r DOPPLER_HZ CHAN_FORGETFACT < <(awk -v v="${UE_SPEED_KMH}" -v fc="${CARRIER_HZ}" -v mu="${NUMEROLOGY:-1}" 'BEGIN{
      c=299792458.0; fd=(v/3.6)*fc/c; slot=0.001/(2^mu);
      tc=(fd>0)?0.423/fd:1e9; ff=slot/tc; if(ff>1)ff=1; if(ff<0)ff=0;
      printf "%.2f %.5f\n", fd, ff }')
    export DOPPLER_HZ CHAN_FORGETFACT
    log "UE speed ${UE_SPEED_KMH} km/h @ ${CARRIER_HZ} Hz -> Doppler ${DOPPLER_HZ} Hz -> forgetfact ${CHAN_FORGETFACT}"
  fi
  local cm="${BASE_DIR}/channelmod_sweep.conf"   # next to the configs so libconfig @include resolves
  cat > "${cm}" <<EOF
# Auto-generated by sweep_iq_width.sh (CHANMOD=1). vrtsim looks up the models
# "server_tx_channel_model" (gNB TX) and "client_tx_channel_model" (UE TX).
channelmod = {
  max_chan  = 10;
  modellist = "vrtsim_sweep_list";
  vrtsim_sweep_list = (
    { model_name = "server_tx_channel_model"; type = "${CHAN_TYPE_DL:-${CHAN_TYPE}}"; ploss_dB = ${CHAN_PLOSS_DB}; noise_power_dB = ${CHAN_NOISE_DB}; forgetfact = ${CHAN_FORGETFACT_DL:-${CHAN_FORGETFACT}}; offset = 0; ds_tdl = ${CHAN_DS_TDL_DL:-${CHAN_DS_TDL}}; },
    { model_name = "client_tx_channel_model"; type = "${CHAN_TYPE}"; ploss_dB = ${CHAN_PLOSS_DB}; noise_power_dB = ${CHAN_NOISE_DB}; forgetfact = ${CHAN_FORGETFACT}; offset = 0; ds_tdl = ${CHAN_DS_TDL}; }
  );
};
EOF
  # vrtsim reads per-UE antenna/channel config from vrtsim.ue_config.[i] on the
  # SERVER; without it each UE defaults to 1x1 TX and a multi-antenna UE aborts
  # ("Server expects UE 0 to have 1 TX antennas"). Emit it for NB_ANT>1.
  if [[ "${UE_NB_ANT_TX}" != "1" || "${UE_NB_ANT_RX}" != "1" ]]; then
    cat >> "${cm}" <<EOF

vrtsim = {
  ue_config = (
    { antennas = "${UE_NB_ANT_TX}x${UE_NB_ANT_RX}"; }
  );
};
EOF
  fi
  cp "${cm}" "${OUT_DIR}/channelmod_sweep.conf" 2>/dev/null || true
  grep -q 'channelmod_sweep.conf' "${RU_CONF}" || printf '\n@include "channelmod_sweep.conf"\n' >> "${RU_CONF}"
  [[ -f "${UE_CONF}" ]] && { grep -q 'channelmod_sweep.conf' "${UE_CONF}" || printf '\n@include "channelmod_sweep.conf"\n' >> "${UE_CONF}"; }
  # The server must know how many RX antennas the client has, else it defaults to 1
  # (client_num_rx_antennas .defintval=1) and models DL for only 1 of the UE's NB_ANT
  # RX antennas -> UE 4-antenna DL combine gets garbage -> synch fails. Pass it explicitly.
  export VRTSIM_RU_EXTRA_ARGS="--vrtsim.chanmod 1 --vrtsim.timescale ${VRTSIM_TIMESCALE} --vrtsim.client-num-rx-antennas ${UE_NB_ANT_RX}"
  export VRTSIM_UE_EXTRA_ARGS="--vrtsim.chanmod 1"
  # Target UL RX SNR: per-slot AGC lives in the UE (client = UL TX path). Pass to the UE only,
  # so the DL (RU server_tx) stays clean and initial sync is unaffected.
  if [[ -n "${CHAN_RX_SNR_DB}" ]]; then
    export VRTSIM_UE_EXTRA_ARGS="${VRTSIM_UE_EXTRA_ARGS} --vrtsim.rx-target-snr-db ${CHAN_RX_SNR_DB}"
  fi
  export UE_NB_ANT_TX="${nbrx}" UE_NB_ANT_RX="${nbtx}"
  log "chanmod ON: type=${CHAN_TYPE} ds_tdl=${CHAN_DS_TDL}us noise=${CHAN_NOISE_DB}dB ploss=${CHAN_PLOSS_DB}dB rx_snr=${CHAN_RX_SNR_DB:-off}dB forgetfact=${CHAN_FORGETFACT} timescale=${VRTSIM_TIMESCALE} ant=${NB_ANT}"
  log "chanmod NOTE: realtime is fragile — if UE will not connect, lower VRTSIM_TIMESCALE; this path needs validation."
}

stop_stack() {
  if (( STACK_TOUCHED == 0 )); then
    return 0
  fi
  set +e
  for pid in "${UE_PID}" "${DU_PID}" "${RU_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    fi
  done
  sudo pkill -TERM nr-uesoftmodem 2>/dev/null || true
  sudo pkill -TERM nr-softmodem 2>/dev/null || true
  sudo pkill -TERM nr-oru 2>/dev/null || true
  sleep 2
  sudo pkill -KILL nr-uesoftmodem 2>/dev/null || true
  sudo pkill -KILL nr-softmodem 2>/dev/null || true
  sudo pkill -KILL nr-oru 2>/dev/null || true
  sudo rm -f /tmp/vrtsim_connection /dev/shm/vrtsim* 2>/dev/null || true
  RU_PID=""; DU_PID=""; UE_PID=""
  set -e
}

cleanup() {
  stop_stack || true
  restore_configs || true
}
trap cleanup EXIT INT TERM

require_files() {
  local path
  for path in "${RU_CONF}" "${DU_CONF}" "${RUN_RU}" "${RUN_DU}" "${RUN_UE}"; do
    [[ -e "${path}" ]] || { echo "Missing required file: ${path}" >&2; exit 1; }
  done
  if [[ "${IPERF_DIRECTION}" != "none" ]]; then
    command -v iperf3 >/dev/null || { echo "iperf3 not found in PATH" >&2; exit 1; }
  fi
}

comp_for_width() {
  local width="$1"
  if [[ "${width}" == "16" ]]; then
    echo 0
  else
    echo 1
  fi
}

patch_conf() {
  local width="$1"
  local comp="$2"
  local conf
  for conf in "${RU_CONF}" "${DU_CONF}"; do
    perl -0pi -e '
      s/(iq_width\s*=\s*)\d+(\s*;)/${1}'"${width}"'${2}/g;
      s/(iq_width_prach\s*=\s*)\d+(\s*;)/${1}'"${width}"'${2}/g;
      s/(compMeth\s*=\s*)\d+(\s*;)/${1}'"${comp}"'${2}/g;
      s/(compMeth_prach\s*=\s*)\d+(\s*;)/${1}'"${comp}"'${2}/g;
    ' "${conf}"
  done
}

wait_for_file() {
  local file="$1" timeout="$2" label="$3"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    [[ -e "${file}" ]] && return 0
    sleep 1
  done
  echo "Timed out waiting for ${label}: ${file}" >&2
  return 1
}

wait_for_log() {
  local regex="$1" file="$2" timeout="$3" label="$4"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if [[ -f "${file}" ]] && grep -Eq "${regex}" "${file}"; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ${label}; regex=${regex}; log=${file}" >&2
  return 1
}

launch_component() {
  local name="$1" script="$2" log_file="$3"
  log "starting ${name}: ${script}" >&2
  setsid "${script}" >"${log_file}" 2>&1 &
  echo $!
}

extract_ue_ip() {
  local ue_log="$1"
  local ip=""
  if [[ -f "${ue_log}" ]]; then
    ip="$(grep -aoE 'UE IPv4: [0-9.]+' "${ue_log}" | tail -n1 | awk '{print $3}' || true)"
    [[ -n "${ip}" ]] || ip="$(grep -aoE 'IPv4 [0-9.]+' "${ue_log}" | tail -n1 | awk '{print $2}' || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(ip -o -4 addr show 2>/dev/null | awk '/oaitun_ue|uesimtun|oaitun/ {sub(/\/.*/, "", $4); print $4; exit}' || true)"
  fi
  echo "${ip}"
}

# Guarantee exactly one fresh iperf3 server on ${IPERF_SERVER}:${IPERF_PORT} inside
# the netns of ${IPERF_SERVER_NETNS_CONTAINER}. Kills any existing iperf3 there first
# so a wedged/duplicate instance can never reset the client's control socket.
ensure_iperf_server() {
  [[ "${IPERF_MANAGE_SERVER}" == "1" ]] || return 0
  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "${IPERF_SERVER_NETNS_CONTAINER}" 2>/dev/null || true)"
  if [[ -z "${pid}" || "${pid}" == "0" ]]; then
    log "WARN: container ${IPERF_SERVER_NETNS_CONTAINER} not found; assuming an iperf3 server already listens on ${IPERF_SERVER}:${IPERF_PORT}"
    return 0
  fi
  sudo nsenter -t "${pid}" -n pkill -x iperf3 2>/dev/null || true
  sleep 1
  sudo nsenter -t "${pid}" -n iperf3 -s -B "${IPERF_SERVER}" -p "${IPERF_PORT}" -D 2>/dev/null || true
  sleep 1
  if sudo nsenter -t "${pid}" -n ss -tln 2>/dev/null | grep -qE "[:.]${IPERF_PORT}([[:space:]]|$)"; then
    log "iperf3 server ready: single instance on ${IPERF_SERVER}:${IPERF_PORT} (netns ${IPERF_SERVER_NETNS_CONTAINER})"
  else
    log "WARN: could not confirm iperf3 server on ${IPERF_SERVER}:${IPERF_PORT} in ${IPERF_SERVER_NETNS_CONTAINER}"
  fi
}

run_iperf_one() {
  local direction="$1" ue_ip="$2" out_json="$3" out_log="$4"
  local reverse=()
  if [[ "${direction}" == "dl" ]]; then
    reverse=(-R)
  fi
  local proto=()
  local server_json="${out_json%.json}.server.json"
  local srv_pid="" ns_pid=""
  if [[ "${IPERF_UDP}" == "1" ]]; then
    proto=(-u -b "${IPERF_UDP_RATE}")
    # UL UDP saturation starves iperf3's TCP control socket (it shares the UL
    # radio path), so --get-server-output is unreliable — it needs the control
    # socket alive at the end. Instead run a one-off JSON-logging server and read
    # the SERVER's locally-counted received rate from its logfile, independent of
    # the control socket. nsenter -n keeps the HOST mount ns, so --logfile lands
    # on the host filesystem where the report parser can read it.
    if [[ "${IPERF_MANAGE_SERVER}" == "1" ]]; then
      ns_pid="$(docker inspect -f '{{.State.Pid}}' "${IPERF_SERVER_NETNS_CONTAINER}" 2>/dev/null || true)"
      if [[ -n "${ns_pid}" && "${ns_pid}" != "0" ]]; then
        sudo nsenter -t "${ns_pid}" -n pkill -x iperf3 2>/dev/null || true
        sleep 1
        sudo rm -f "${server_json}" 2>/dev/null || true
        sudo nsenter -t "${ns_pid}" -n iperf3 -s -B "${IPERF_SERVER}" -p "${IPERF_PORT}" -1 --json --logfile "${server_json}" &
        srv_pid=$!
        # Verify the control port is actually LISTENing before the client connects
        # (unverified launch raced ahead of bind -> client connect timeout).
        local r=0
        while ! sudo nsenter -t "${ns_pid}" -n ss -tln 2>/dev/null | grep -qE "[:.]${IPERF_PORT}([[:space:]]|$)" && (( r < 10 )); do sleep 1; ((r++)); done
        if sudo nsenter -t "${ns_pid}" -n ss -tln 2>/dev/null | grep -qE "[:.]${IPERF_PORT}([[:space:]]|$)"; then
          log "iperf3 one-off UDP logging server LISTENING on ${IPERF_SERVER}:${IPERF_PORT} (after ${r}s) -> ${server_json}"
        else
          log "WARN: one-off UDP server not confirmed LISTENING on ${IPERF_SERVER}:${IPERF_PORT} after ${r}s"
        fi
      else
        log "WARN: container ${IPERF_SERVER_NETNS_CONTAINER} not found; relying on client-side stats only"
      fi
    fi
  else
    ensure_iperf_server
  fi
  log "route to server: $(ip route get "${IPERF_SERVER}" from "${ue_ip}" 2>/dev/null | head -1)"
  log "running iperf3 ${direction}: server=${IPERF_SERVER}, ue_ip=${ue_ip}, seconds=${IPERF_SECONDS}, udp=${IPERF_UDP}"
  local client_rc=0
  iperf3 -J -c "${IPERF_SERVER}" -p "${IPERF_PORT}" -B "${ue_ip}" -t "${IPERF_SECONDS}" -P "${IPERF_PARALLEL}" --connect-timeout "${IPERF_CONNECT_TIMEOUT_MS}" "${proto[@]}" "${reverse[@]}" >"${out_json}" 2>"${out_log}" || client_rc=$?
  if [[ -n "${srv_pid}" ]]; then
    # Let the one-off server self-exit (it flushes JSON on test end); only force
    # it down if it wedges, so we never truncate a half-written logfile.
    local w=0
    while kill -0 "${srv_pid}" 2>/dev/null && (( w < 15 )); do sleep 1; ((w++)); done
    kill -0 "${srv_pid}" 2>/dev/null && sudo nsenter -t "${ns_pid}" -n pkill -x iperf3 2>/dev/null || true
    wait "${srv_pid}" 2>/dev/null || true
    sudo chmod a+r "${server_json}" 2>/dev/null || true
  fi
  if [[ "${IPERF_UDP}" == "1" ]]; then
    # Success = the server recorded a received rate, even if the client control
    # socket died (expected under UL saturation).
    if [[ -s "${server_json}" ]] && grep -q '"bits_per_second"' "${server_json}"; then
      return 0
    fi
    return 1
  fi
  return "${client_rc}"
}

write_csv_header() {
  if [[ ! -f "${CSV}" ]]; then
    echo 'timestamp,iq_width,comp_method,status,ue_ip,ue_count,channel_model,carrier_hz,tx_bw_prb,rx_bw_prb,dl_rb,ul_rb,numerology,nb_tx,nb_rx,snr_samples,snr_db_avg,snr_db_min,snr_db_max,fh_samples,fh_rx_mbps_avg,fh_tx_mbps_avg,fh_total_mbps_avg,fh_total_mbps_max,iperf_ul_mbps,iperf_dl_mbps,ul_jitter_ms,ul_loss_pct,fh_late_total,fh_lead_mean,fh_lead_min,ul_sym_present_pct,trial_dir,notes' >"${CSV}"
  fi
}

append_metrics() {
  local width="$1" comp="$2" status="$3" ue_ip="$4" trial_dir="$5" notes="$6"
  python3 - "$width" "$comp" "$status" "$ue_ip" "$trial_dir" "$notes" "$FH_DROP_FIRST" <<'PY' >>"${CSV}"
import csv, json, os, re, statistics, sys, datetime
width, comp, status, ue_ip, trial_dir, notes, drop_first = sys.argv[1:8]
drop_first = int(drop_first)


def read_text(path):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def first_match(pattern, text, default=""):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else default


def conf_value(text, name, default=""):
    return first_match(r"\b" + re.escape(name) + r"\s*=\s*(?:\[\s*)?([0-9]+)", text, default)


def normalize_carrier(value):
    if value in ("", None):
        return ""
    try:
        n = int(value)
    except ValueError:
        return value
    if n < 100000000:
        n *= 1000
    return str(n)


def trial_text(name):
    return read_text(os.path.join(trial_dir, name))

run_dir = os.path.dirname(trial_dir)
ru_conf = read_text(os.path.join(run_dir, "ru_test.conf.orig"))
du_conf = read_text(os.path.join(run_dir, "du_test.conf.orig"))
ru_log = trial_text("ru.log")
du_log = trial_text("du.log")
ue_log = trial_text("ue.log")
all_logs = "\n".join((ru_log, du_log, ue_log))

fh = []
for text in (du_log, ru_log):
    for line in text.splitlines():
        m = re.search(r"\[FH LOAD\].*?rx=([0-9.]+) Mbps tx=([0-9.]+) Mbps total=([0-9.]+) Mbps", line)
        if m:
            fh.append(tuple(float(x) for x in m.groups()))
fh_used = fh[drop_first:] if len(fh) > drop_first else fh

snrs = [float(x) for x in re.findall(r"\bSNR\s+(-?[0-9]+(?:\.[0-9]+)?)\s+dB", du_log)]
# Real time-domain UL RX SNR injected/measured by vrtsim AGC (ue.log). Preferred over
# the gNB ULSCH SNR (post-FFT, inflated by processing gain) when AGC was active.
td_snrs = [float(x) for x in re.findall(r"RX SNR \(time-domain[^)]*\):\s*(-?[0-9]+(?:\.[0-9]+)?)\s*dB", ue_log)]
rx_snrs = td_snrs if td_snrs else snrs
ue_ips = set(re.findall(r"UE IPv4:\s*([0-9.]+)", ue_log))
ue_ids = set(re.findall(r"\[UE\s+(\d+)\]", ue_log))
tun_ids = set(re.findall(r"TUN Interface\s+oaitun_ue(\d+)", ue_log))
ue_count = len(ue_ips) or len(tun_ids) or len(ue_ids) or (1 if ue_log.strip() else 0)

channel_model = first_match(r'--device\.name"?\s+"?([^"\s]+)', all_logs)
if not channel_model:
    channel_model = first_match(r'device\.name\s+([^"\s]+)', all_logs)
if not channel_model:
    channel_model = first_match(r'channel[_ -]?model\s*[=:]\s*([^"\s,]+)', all_logs, "not_logged")

carrier_hz = first_match(r'"-C"\s+"([0-9]+)"', ue_log)
if not carrier_hz:
    carrier_hz = first_match(r'\b-C\s+([0-9]+)', ue_log)
if not carrier_hz:
    carrier_hz = first_match(r'DL freq\s+([0-9]+)', ue_log)
if not carrier_hz:
    carrier_hz = normalize_carrier(conf_value(ru_conf, "carrier_tx"))

numerology = first_match(r'--numerology"?\s+"?([0-9]+)', all_logs)
if not numerology:
    numerology = first_match(r'fp->numerology_index=([0-9]+)', du_log, conf_value(du_conf, "subcarrierSpacing"))

dl_rb = first_match(r'N_RB_DL\s+([0-9]+)', all_logs, conf_value(du_conf, "dl_carrierBandwidth"))
ul_rb = conf_value(du_conf, "ul_carrierBandwidth", dl_rb)

def avg_fh(idx):
    return statistics.mean(x[idx] for x in fh_used) if fh_used else 0.0

def max_total():
    return max((x[2] for x in fh_used), default=0.0)

def iperf_mbps(path):
    # Prefer the server's locally-recorded received rate: under UDP UL saturation
    # the client control socket dies, so the client 'sum'/--get-server-output are
    # unreliable (they report the OFFERED rate). Resolution order:
    #   1) server end.sum (clean finish)
    #   2) server per-interval received rates, averaged (control socket died
    #      before the end summary, but the server still logged each second)
    #   3) client side (last resort; over-reports for UDP UL)
    server_path = (path[:-5] if path.endswith(".json") else path) + ".server.json"
    if os.path.exists(server_path) and os.path.getsize(server_path) > 0:
        try:
            sd = json.load(open(server_path))
        except Exception:
            sd = {}
        end = sd.get("end", {})
        for key in ("sum", "sum_received"):
            val = end.get(key, {})
            if isinstance(val, dict) and val.get("bits_per_second"):
                return float(val["bits_per_second"]) / 1e6
        ivs = [iv.get("sum", {}).get("bits_per_second") for iv in sd.get("intervals", [])]
        ivs = [b / 1e6 for b in ivs if b]
        if len(ivs) >= 3:          # drop ramp-up start + teardown tail
            ivs = ivs[1:-1]
        if ivs:
            return sum(ivs) / len(ivs)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        try:
            cd = json.load(open(path))
        except Exception:
            cd = {}
        end = cd.get("end", {})
        for key in ("sum_received", "sum_sent", "sum"):
            val = end.get(key, {})
            if isinstance(val, dict) and val.get("bits_per_second"):
                return float(val["bits_per_second"]) / 1e6
    return 0.0

def ul_latency(path):
    # UL latency/reliability from the iperf3 UDP server JSON. Under UDP UL saturation the
    # client control socket dies so end.sum is empty -> fall back to per-interval jitter/loss.
    server_path = (path[:-5] if path.endswith(".json") else path) + ".server.json"
    jit, loss = "", ""
    if os.path.exists(server_path) and os.path.getsize(server_path) > 0:
        try:
            sd = json.load(open(server_path))
        except Exception:
            sd = {}
        s = sd.get("end", {}).get("sum", {})
        if s.get("jitter_ms") is not None:
            jit = f"{float(s['jitter_ms']):.3f}"
        if s.get("lost_percent") is not None:
            loss = f"{float(s['lost_percent']):.2f}"
        if jit == "" or loss == "":
            ivs = [iv.get("sum", {}) for iv in sd.get("intervals", [])]
            ivs = [x for x in ivs if x.get("packets")]
            if len(ivs) >= 3:
                ivs = ivs[1:-1]            # drop ramp-up + teardown tail
            if ivs:
                js = [float(x["jitter_ms"]) for x in ivs if x.get("jitter_ms") is not None]
                if js and jit == "":
                    jit = f"{sum(js)/len(js):.3f}"
                tot = sum(int(x.get("packets", 0)) for x in ivs)
                lost = sum(int(x.get("lost_packets", 0)) for x in ivs)
                if tot > 0 and loss == "":
                    loss = f"{100.0 * lost / tot:.2f}"
    return jit, loss

def fh_lead_stats():
    # R1 real FH-latency proxy: U-plane arrival lead-time (symbols) from oaioran_ru.c instrumentation.
    # lower mean = less margin = higher FH latency. Also total up_late (FH packets dropped as too-late).
    rows = re.findall(r'FH lead-time symbols: mean=([0-9.\-]+) min=(-?[0-9]+) \(n=([0-9]+)\)', ru_log)
    late = sum(int(x) for x in re.findall(r'Packets late: ([0-9]+)', ru_log))
    if not rows:
        return "", "", late
    tot = sum(int(n) for _, _, n in rows)
    wmean = sum(float(mu) * int(n) for mu, _, n in rows) / tot if tot else 0.0
    gmin = min(int(mn) for _, mn, _ in rows)
    return f"{wmean:.2f}", str(gmin), late

def ul_sym_present():
    # UL FH-latency metric: fraction of expected UL symbols present (arrived) at DU read time.
    # From oaioran.c instrumentation in du.log. Tightening Ta4 -> late UL symbols dropped -> rate falls.
    rows = re.findall(r'UL sym present: ([0-9]+)/([0-9]+) \(', du_log)
    tp = sum(int(p) for p, _ in rows)
    te = sum(int(e) for _, e in rows)
    return f"{100.0 * tp / te:.2f}" if te else ""

_jit, _loss = ul_latency(os.path.join(trial_dir, 'iperf_ul.json'))
_lead_mean, _lead_min, _late = fh_lead_stats()
_ul_present = ul_sym_present()

def fmt(value):
    return f"{value:.3f}" if isinstance(value, float) else str(value)

row = {
    "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
    "iq_width": width,
    "comp_method": comp,
    "status": status,
    "ue_ip": ue_ip,
    "ue_count": ue_count,
    "channel_model": channel_model,
    "carrier_hz": carrier_hz,
    "tx_bw_prb": conf_value(ru_conf, "tx_bw", dl_rb),
    "rx_bw_prb": conf_value(ru_conf, "rx_bw", ul_rb),
    "dl_rb": dl_rb,
    "ul_rb": ul_rb,
    "numerology": numerology,
    "nb_tx": conf_value(ru_conf, "nb_tx", conf_value(du_conf, "nb_tx", "")),
    "nb_rx": conf_value(ru_conf, "nb_rx", conf_value(du_conf, "nb_rx", "")),
    "snr_samples": len(rx_snrs),
    "snr_db_avg": fmt(statistics.mean(rx_snrs)) if rx_snrs else "",
    "snr_db_min": fmt(min(rx_snrs)) if rx_snrs else "",
    "snr_db_max": fmt(max(rx_snrs)) if rx_snrs else "",
    "fh_samples": len(fh_used),
    "fh_rx_mbps_avg": f"{avg_fh(0):.3f}",
    "fh_tx_mbps_avg": f"{avg_fh(1):.3f}",
    "fh_total_mbps_avg": f"{avg_fh(2):.3f}",
    "fh_total_mbps_max": f"{max_total():.3f}",
    "iperf_ul_mbps": f"{iperf_mbps(os.path.join(trial_dir, 'iperf_ul.json')):.3f}",
    "iperf_dl_mbps": f"{iperf_mbps(os.path.join(trial_dir, 'iperf_dl.json')):.3f}",
    "ul_jitter_ms": _jit,
    "ul_loss_pct": _loss,
    "fh_late_total": _late,
    "fh_lead_mean": _lead_mean,
    "fh_lead_min": _lead_min,
    "ul_sym_present_pct": _ul_present,
    "trial_dir": trial_dir,
    "notes": notes.replace("\n", " "),
}
writer = csv.DictWriter(sys.stdout, fieldnames=list(row.keys()))
writer.writerow(row)
PY
}

write_report() {
  python3 - "${CSV}" "${REPORT}" <<'PY'
import csv, os, re, statistics, sys
csv_path, report_path = sys.argv[1:3]


def read_text(path):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def first_match(pattern, text, default=""):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else default


def conf_value(text, name, default=""):
    return first_match(r"\b" + re.escape(name) + r"\s*=\s*(?:\[\s*)?([0-9]+)", text, default)


def normalize_carrier(value):
    if value in ("", None):
        return ""
    try:
        n = int(value)
    except ValueError:
        return value
    if n < 100000000:
        n *= 1000
    return str(n)


def ensure(row, key, value):
    if not row.get(key):
        row[key] = str(value)


def enrich(row):
    row = dict(row)
    trial_dir = row.get("trial_dir", "")
    run_dir = os.path.dirname(trial_dir)
    ru_conf = read_text(os.path.join(run_dir, "ru_test.conf.orig"))
    du_conf = read_text(os.path.join(run_dir, "du_test.conf.orig"))
    ru_log = read_text(os.path.join(trial_dir, "ru.log"))
    du_log = read_text(os.path.join(trial_dir, "du.log"))
    ue_log = read_text(os.path.join(trial_dir, "ue.log"))
    all_logs = "\n".join((ru_log, du_log, ue_log))

    snrs = [float(x) for x in re.findall(r"\bSNR\s+(-?[0-9]+(?:\.[0-9]+)?)\s+dB", du_log)]
    # Real time-domain UL RX SNR injected/measured by vrtsim AGC (ue.log). Preferred
    # over the gNB ULSCH SNR (which is post-FFT and inflated by processing gain).
    td_snrs = [float(x) for x in re.findall(r"RX SNR \(time-domain[^)]*\):\s*(-?[0-9]+(?:\.[0-9]+)?)\s*dB", ue_log)]
    ue_ips = set(re.findall(r"UE IPv4:\s*([0-9.]+)", ue_log))
    ue_ids = set(re.findall(r"\[UE\s+(\d+)\]", ue_log))
    tun_ids = set(re.findall(r"TUN Interface\s+oaitun_ue(\d+)", ue_log))

    ensure(row, "ue_count", len(ue_ips) or len(tun_ids) or len(ue_ids) or (1 if ue_log.strip() else 0))
    ensure(row, "channel_model", first_match(r'--device\.name"?\s+"?([^"\s]+)', all_logs) or first_match(r'device\.name\s+([^"\s]+)', all_logs) or first_match(r'channel[_ -]?model\s*[=:]\s*([^"\s,]+)', all_logs, "not_logged"))

    carrier_hz = first_match(r'"-C"\s+"([0-9]+)"', ue_log) or first_match(r'\b-C\s+([0-9]+)', ue_log) or first_match(r'DL freq\s+([0-9]+)', ue_log) or normalize_carrier(conf_value(ru_conf, "carrier_tx"))
    ensure(row, "carrier_hz", carrier_hz)

    numerology = first_match(r'--numerology"?\s+"?([0-9]+)', all_logs) or first_match(r'fp->numerology_index=([0-9]+)', du_log, conf_value(du_conf, "subcarrierSpacing"))
    dl_rb = first_match(r'N_RB_DL\s+([0-9]+)', all_logs, conf_value(du_conf, "dl_carrierBandwidth"))
    ul_rb = conf_value(du_conf, "ul_carrierBandwidth", dl_rb)
    ensure(row, "tx_bw_prb", conf_value(ru_conf, "tx_bw", dl_rb))
    ensure(row, "rx_bw_prb", conf_value(ru_conf, "rx_bw", ul_rb))
    ensure(row, "dl_rb", dl_rb)
    ensure(row, "ul_rb", ul_rb)
    ensure(row, "numerology", numerology)
    ensure(row, "nb_tx", conf_value(ru_conf, "nb_tx", conf_value(du_conf, "nb_tx", "")))
    ensure(row, "nb_rx", conf_value(ru_conf, "nb_rx", conf_value(du_conf, "nb_rx", "")))
    rx_snrs = td_snrs if td_snrs else snrs
    ensure(row, "snr_samples", len(rx_snrs))
    ensure(row, "snr_db_avg", f"{statistics.mean(rx_snrs):.3f}" if rx_snrs else "")
    ensure(row, "snr_db_min", f"{min(rx_snrs):.3f}" if rx_snrs else "")
    ensure(row, "snr_db_max", f"{max(rx_snrs):.3f}" if rx_snrs else "")
    # "(td)" marks the real time-domain RX SNR; otherwise it's the gNB ULSCH estimate.
    row["snr_triplet"] = (f"{row.get('snr_db_avg', '')}/{row.get('snr_db_min', '')}/{row.get('snr_db_max', '')}" + (" (td)" if td_snrs else "")) if row.get("snr_db_avg") else "n/a"
    return row

rows = []
try:
    with open(csv_path, newline="") as f:
        rows = [enrich(r) for r in csv.DictReader(f)]
except FileNotFoundError:
    rows = []

with open(report_path, "w") as out:
    out.write("# IQ Width Sweep Report\n\n")
    out.write(f"Source CSV: `{csv_path}`\n\n")
    out.write("| IQ width | compMeth | status | UE # | channel | carrier Hz | BW tx/rx PRB | RB dl/ul | mu | ant tx/rx | RX SNR avg/min/max dB | FH avg Mbps | FH max Mbps | UL iperf Mbps | DL iperf Mbps | samples |\n")
    out.write("|---:|---:|---|---:|---|---:|---|---|---:|---|---|---:|---:|---:|---:|---:|\n")
    for r in rows:
        out.write("| {iq_width} | {comp_method} | {status} | {ue_count} | {channel_model} | {carrier_hz} | {tx_bw_prb}/{rx_bw_prb} | {dl_rb}/{ul_rb} | {numerology} | {nb_tx}/{nb_rx} | {snr_triplet} | {fh_total_mbps_avg} | {fh_total_mbps_max} | {iperf_ul_mbps} | {iperf_dl_mbps} | {fh_samples} |\n".format(**r))
    out.write("\n## Radio Context\n\n")
    if rows:
        r = rows[0]
        out.write(f"- Carrier: `{r.get('carrier_hz', '')}` Hz\n")
        out.write(f"- Bandwidth/RB: tx/rx `{r.get('tx_bw_prb', '')}/{r.get('rx_bw_prb', '')}` PRB, dl/ul `{r.get('dl_rb', '')}/{r.get('ul_rb', '')}` RB\n")
        out.write(f"- Numerology: `{r.get('numerology', '')}`\n")
        out.write(f"- Antennas: tx/rx `{r.get('nb_tx', '')}/{r.get('nb_rx', '')}` (gNB+UE antenna count: `{os.environ.get('NB_ANT','1')}`)\n")
        out.write(f"- Channel/device model: `{r.get('channel_model', '')}`\n")
        # --- Channel setup (FH-latency experiment context) ---
        chanmod = os.environ.get("CHANMOD", "0") == "1"
        if not chanmod:
            out.write("- Channel setup: **ideal passthrough (chanmod OFF)** — no TDL/delay-spread/mobility; "
                      "RX SNR is set only by `iq_width` quantization + ploss. Enable with `CHANMOD=1`.\n")
        else:
            out.write(f"- Channel setup (chanmod ON):\n")
            out.write(f"    - Profile (TDL-A etc): `{os.environ.get('CHAN_TYPE','AWGN')}`\n")
            out.write(f"    - Delay spread (ds_tdl): `{os.environ.get('CHAN_DS_TDL','0')}` us\n")
            out.write(f"    - Channel noise / path-loss: `{os.environ.get('CHAN_NOISE_DB','')}` dB / `{os.environ.get('CHAN_PLOSS_DB','0')}` dB\n")
            out.write(f"    - UE mobility (forgetfact PROXY; max_Doppler NOT implemented): `{os.environ.get('CHAN_FORGETFACT','0')}`\n")
            out.write(f"    - vrtsim timescale: `{os.environ.get('VRTSIM_TIMESCALE','1.0')}`\n")
        # RX SNR actually measured at the gNB (UL ULSCH traces), per trial:
        snr_line = ", ".join(
            f"iq{r2.get('iq_width','?')}={r2.get('snr_db_avg','n/a')}dB(min {r2.get('snr_db_min','?')}/max {r2.get('snr_db_max','?')})"
            for r2 in rows)
        out.write(f"- Measured RX SNR (UL, gNB): {snr_line}\n")
    out.write("\n## Notes\n\n")
    out.write("- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.\n")
    out.write("- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.\n")
    out.write("- FH load is parsed from `[FH LOAD]` log lines after dropping the first warmup samples.\n")
    out.write("- SNR is parsed from DU `ULSCH ... trace` lines containing `SNR ... dB`. `n/a` means no such lines appeared in that trial.\n")
PY
}

run_trial() {
  local width="$1"
  local comp status="ok" notes="" ue_ip=""
  comp="$(comp_for_width "${width}")"
  local trial_dir="${OUT_DIR}/iq${width}"
  mkdir -p "${trial_dir}"

  log "=== IQ width ${width}, compMeth ${comp} ==="

  if (( DRY_RUN )); then
    patch_conf "${width}" "${comp}"
    append_metrics "${width}" "${comp}" "dry-run" "" "${trial_dir}" "not launched"
    write_report
    return 0
  fi

  sudo -n true
  patch_conf "${width}" "${comp}"
  STACK_TOUCHED=1
  stop_stack

  RU_PID="$(launch_component RU "${RUN_RU}" "${trial_dir}/ru.log")"
  wait_for_file /tmp/vrtsim_connection "${RU_WAIT_SECONDS}" "RU VRTSIM connection" || status="ru-timeout"

  if [[ "${status}" == "ok" ]]; then
    DU_PID="$(launch_component DU "${RUN_DU}" "${trial_dir}/du.log")"
    wait_for_log 'got sync|Port 1 Link Up' "${trial_dir}/du.log" "${DU_WAIT_SECONDS}" "DU sync" || status="du-timeout"
  fi

  if [[ "${status}" == "ok" ]]; then
    if [[ "${UE_START_DELAY_SECONDS}" != "0" ]]; then
      log "waiting ${UE_START_DELAY_SECONDS}s before UE start"
      sleep "${UE_START_DELAY_SECONDS}"
    fi
    UE_PID="$(launch_component UE "${RUN_UE}" "${trial_dir}/ue.log")"
    wait_for_log 'TUN Interface .*successfully configured|Received PDU Session Establishment Accept' "${trial_dir}/ue.log" "${UE_WAIT_SECONDS}" "UE PDU session" || status="ue-timeout"
  fi

  if [[ "${status}" == "ok" ]]; then
    ue_ip="$(extract_ue_ip "${trial_dir}/ue.log")"
    if [[ -z "${ue_ip}" ]]; then
      status="no-ue-ip"
      notes="UE tunnel IP not detected"
    else
      sleep "${SETTLE_SECONDS}"
      case "${IPERF_DIRECTION}" in
        ul)
          run_iperf_one ul "${ue_ip}" "${trial_dir}/iperf_ul.json" "${trial_dir}/iperf_ul.log" || notes="UL iperf failed"
          ;;
        dl)
          run_iperf_one dl "${ue_ip}" "${trial_dir}/iperf_dl.json" "${trial_dir}/iperf_dl.log" || notes="DL iperf failed"
          ;;
        both)
          run_iperf_one ul "${ue_ip}" "${trial_dir}/iperf_ul.json" "${trial_dir}/iperf_ul.log" || notes="UL iperf failed"
          run_iperf_one dl "${ue_ip}" "${trial_dir}/iperf_dl.json" "${trial_dir}/iperf_dl.log" || notes="${notes} DL iperf failed"
          ;;
        none)
          notes="iperf skipped"
          ;;
        *)
          status="bad-iperf-direction"
          notes="invalid IPERF_DIRECTION=${IPERF_DIRECTION}"
          ;;
      esac
      sleep "${SETTLE_SECONDS}"
    fi
  fi

  append_metrics "${width}" "${comp}" "${status}" "${ue_ip}" "${trial_dir}" "${notes}"
  write_report
  stop_stack
  sleep "${BETWEEN_TRIAL_SECONDS}"
}

main() {
  require_files
  build_chanmod
  write_csv_header
  log "output: ${OUT_DIR}"
  log "widths: ${WIDTHS}"
  log "channel: chanmod=${CHANMOD} type=${CHAN_TYPE} ds_tdl=${CHAN_DS_TDL}us noise=${CHAN_NOISE_DB}dB forgetfact=${CHAN_FORGETFACT} ant=${NB_ANT}x${NB_ANT}"
  log "iperf: direction=${IPERF_DIRECTION} server=${IPERF_SERVER}:${IPERF_PORT} seconds=${IPERF_SECONDS} parallel=${IPERF_PARALLEL}"

  local width
  for width in ${WIDTHS}; do
    case "${width}" in
      8|9|10|12|16) run_trial "${width}" ;;
      *) echo "Unsupported width in sweep: ${width}" >&2; exit 2 ;;
    esac
  done

  restore_configs
  log "summary: ${CSV}"
  log "report: ${REPORT}"
}

main "$@"
