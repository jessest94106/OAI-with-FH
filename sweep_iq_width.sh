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
IPERF_PROTOCOL="${IPERF_PROTOCOL:-udp}"   # tcp or udp
IPERF_BITRATE="${IPERF_BITRATE:-100M}"    # UDP target bitrate; ignored for TCP
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
  --iperf-protocol P       tcp or udp. Default: ${IPERF_PROTOCOL}
  --iperf-bitrate B        UDP target bitrate (e.g. 50M, 100M). Default: ${IPERF_BITRATE}
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
    --iperf-protocol) IPERF_PROTOCOL="$2"; shift 2 ;;
    --iperf-bitrate) IPERF_BITRATE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; CSV="${OUT_DIR}/summary.csv"; REPORT="${OUT_DIR}/report.md"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"

RU_BAK="${OUT_DIR}/ru_test.conf.orig"
DU_BAK="${OUT_DIR}/du_test.conf.orig"
cp "${RU_CONF}" "${RU_BAK}"
cp "${DU_CONF}" "${DU_BAK}"

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
    RESTORED=1
  fi
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
  local prach_width=16
  local prach_comp=0
  local conf
  for conf in "${RU_CONF}" "${DU_CONF}"; do
    perl -0pi -e '
      s/(iq_width\s*=\s*)\d+(\s*;)/${1}'"${width}"'${2}/g;
      s/(iq_width_prach\s*=\s*)\d+(\s*;)/${1}'"${prach_width}"'${2}/g;
      s/(compMeth\s*=\s*)\d+(\s*;)/${1}'"${comp}"'${2}/g;
      s/(compMeth_prach\s*=\s*)\d+(\s*;)/${1}'"${prach_comp}"'${2}/g;
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

run_iperf_one() {
  local direction="$1" ue_ip="$2" out_json="$3" out_log="$4"
  local reverse=() proto_flags=()
  if [[ "${direction}" == "dl" ]]; then
    reverse=(-R)
  fi
  if [[ "${IPERF_PROTOCOL}" == "udp" ]]; then
    proto_flags=(-u -b "${IPERF_BITRATE}")
  fi
  log "running iperf3 ${IPERF_PROTOCOL} ${direction}: server=${IPERF_SERVER}, ue_ip=${ue_ip}, seconds=${IPERF_SECONDS}"
  if iperf3 -J -c "${IPERF_SERVER}" -p "${IPERF_PORT}" -B "${ue_ip}" -t "${IPERF_SECONDS}" -P "${IPERF_PARALLEL}" "${proto_flags[@]}" "${reverse[@]}" >"${out_json}" 2>"${out_log}"; then
    return 0
  fi
  return 1
}

write_csv_header() {
  if [[ ! -f "${CSV}" ]]; then
    echo 'timestamp,iq_width,comp_method,status,ue_ip,ue_count,channel_model,channel_model_id,delay_spread_ns,mobility_mps,carrier_hz,tx_bw_prb,rx_bw_prb,dl_rb,ul_rb,numerology,nb_tx,nb_rx,snr_samples,snr_db_avg,snr_db_min,snr_db_max,fh_samples,fh_rx_mbps_avg,fh_tx_mbps_avg,fh_total_mbps_avg,fh_total_mbps_max,iperf_ul_mbps,iperf_dl_mbps,trial_dir,notes' >"${CSV}"
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


def option_value(text, names, default=""):
    for name in names:
        escaped = re.escape(name)
        patterns = [
            r"--" + escaped + r"(?:=|\s+)\"?([^\"\s]+)",
            r"\b" + escaped + r"\s*[=:]\s*\"?([^\"\s,;]+)",
        ]
        for pattern in patterns:
            value = first_match(pattern, text)
            if value:
                return value
    return default


def tdl_name(model_id):
    try:
        model = int(model_id)
    except (TypeError, ValueError):
        return ""
    if 0 <= model <= 4:
        return f"TDL-{chr(65 + model)}"
    return ""


def vrtsim_channel_context(text):
    result = {
        "channel_model": "",
        "channel_model_id": "",
        "delay_spread_ns": "",
        "mobility_mps": "",
        "path_loss_db": "",
        "noise_power_sample": "",
    }
    result["path_loss_db"] = first_match(r"path_loss_dB=([+-]?[0-9.]+)", text)
    result["noise_power_sample"] = first_match(r"VRTSIM:\s+Noise power\s+([0-9]+)\s+sample value", text)
    patterns = [
        r"VRTSIM:\s+UE\s+\d+(?:\s+channel)?\s+-.*?Model\s+([0-4])\s+\((TDL-[A-E])\).*?DS\s+([0-9.]+)\s*ns.*?Speed\s+([0-9.]+)\s*m/s",
        r"Model\s+([0-4])\s+\((TDL-[A-E])\).*?DS\s+([0-9.]+)\s*ns.*?Speed\s+([0-9.]+)\s*m/s",
    ]
    for pattern in patterns:
        m = re.search(pattern, text)
        if m:
            result["channel_model_id"] = m.group(1)
            result["channel_model"] = m.group(2)
            result["delay_spread_ns"] = m.group(3)
            result["mobility_mps"] = m.group(4)
            return result

    model_id = option_value(text, ["vrtsim.cirdb_model_id", "cirdb_model_id"])
    delay_spread = option_value(text, ["vrtsim.cirdb_ds_ns", "cirdb_ds_ns"])
    mobility = option_value(text, ["vrtsim.cirdb_speed_mps", "cirdb_speed_mps"])
    model = tdl_name(model_id)
    if model:
        result["channel_model_id"] = model_id
        result["channel_model"] = model
    if delay_spread:
        result["delay_spread_ns"] = delay_spread
    if mobility:
        result["mobility_mps"] = mobility

    legacy = first_match(r'channel[_ -]?model\s*[=:]\s*([^"\s,]+)', text)
    if legacy and legacy.lower() != "vrtsim":
        result["channel_model"] = legacy

    if not result["channel_model"] and "vrtsim" in text.lower():
        result["channel_model"] = "TDL-A"
        result["channel_model_id"] = result["channel_model_id"] or "0"
        result["delay_spread_ns"] = result["delay_spread_ns"] or "10.0"
        result["mobility_mps"] = result["mobility_mps"] or "1.5"
    return result


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
ue_ips = set(re.findall(r"UE IPv4:\s*([0-9.]+)", ue_log))
ue_ids = set(re.findall(r"\[UE\s+(\d+)\]", ue_log))
tun_ids = set(re.findall(r"TUN Interface\s+oaitun_ue(\d+)", ue_log))
ue_count = len(ue_ips) or len(tun_ids) or len(ue_ids) or (1 if ue_log.strip() else 0)
channel_context = vrtsim_channel_context(all_logs)

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
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return 0.0
    try:
        data = json.load(open(path))
    except Exception:
        return 0.0
    end = data.get("end", {})
    candidates = []
    for key in ("sum_received", "sum_sent", "sum"):
        val = end.get(key, {})
        if isinstance(val, dict) and "bits_per_second" in val:
            candidates.append(float(val["bits_per_second"]) / 1e6)
    return candidates[0] if candidates else 0.0

def fmt(value):
    return f"{value:.3f}" if isinstance(value, float) else str(value)

row = {
    "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
    "iq_width": width,
    "comp_method": comp,
    "status": status,
    "ue_ip": ue_ip,
    "ue_count": ue_count,
    "channel_model": channel_context["channel_model"] or "not_logged",
    "channel_model_id": channel_context["channel_model_id"],
    "delay_spread_ns": channel_context["delay_spread_ns"],
    "mobility_mps": channel_context["mobility_mps"],
    "carrier_hz": carrier_hz,
    "tx_bw_prb": conf_value(ru_conf, "tx_bw", dl_rb),
    "rx_bw_prb": conf_value(ru_conf, "rx_bw", ul_rb),
    "dl_rb": dl_rb,
    "ul_rb": ul_rb,
    "numerology": numerology,
    "nb_tx": conf_value(ru_conf, "nb_tx", conf_value(du_conf, "nb_tx", "")),
    "nb_rx": conf_value(ru_conf, "nb_rx", conf_value(du_conf, "nb_rx", "")),
    "snr_samples": len(snrs),
    "snr_db_avg": fmt(statistics.mean(snrs)) if snrs else "",
    "snr_db_min": fmt(min(snrs)) if snrs else "",
    "snr_db_max": fmt(max(snrs)) if snrs else "",
    "fh_samples": len(fh_used),
    "fh_rx_mbps_avg": f"{avg_fh(0):.3f}",
    "fh_tx_mbps_avg": f"{avg_fh(1):.3f}",
    "fh_total_mbps_avg": f"{avg_fh(2):.3f}",
    "fh_total_mbps_max": f"{max_total():.3f}",
    "iperf_ul_mbps": f"{iperf_mbps(os.path.join(trial_dir, 'iperf_ul.json')):.3f}",
    "iperf_dl_mbps": f"{iperf_mbps(os.path.join(trial_dir, 'iperf_dl.json')):.3f}",
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


def option_value(text, names, default=""):
    for name in names:
        escaped = re.escape(name)
        patterns = [
            r"--" + escaped + r"(?:=|\s+)\"?([^\"\s]+)",
            r"\b" + escaped + r"\s*[=:]\s*\"?([^\"\s,;]+)",
        ]
        for pattern in patterns:
            value = first_match(pattern, text)
            if value:
                return value
    return default


def tdl_name(model_id):
    try:
        model = int(model_id)
    except (TypeError, ValueError):
        return ""
    if 0 <= model <= 4:
        return f"TDL-{chr(65 + model)}"
    return ""


def vrtsim_channel_context(text):
    result = {
        "channel_model": "",
        "channel_model_id": "",
        "delay_spread_ns": "",
        "mobility_mps": "",
        "path_loss_db": "",
        "noise_power_sample": "",
    }
    result["path_loss_db"] = first_match(r"path_loss_dB=([+-]?[0-9.]+)", text)
    result["noise_power_sample"] = first_match(r"VRTSIM:\s+Noise power\s+([0-9]+)\s+sample value", text)
    patterns = [
        r"VRTSIM:\s+UE\s+\d+(?:\s+channel)?\s+-.*?Model\s+([0-4])\s+\((TDL-[A-E])\).*?DS\s+([0-9.]+)\s*ns.*?Speed\s+([0-9.]+)\s*m/s",
        r"Model\s+([0-4])\s+\((TDL-[A-E])\).*?DS\s+([0-9.]+)\s*ns.*?Speed\s+([0-9.]+)\s*m/s",
    ]
    for pattern in patterns:
        m = re.search(pattern, text)
        if m:
            result["channel_model_id"] = m.group(1)
            result["channel_model"] = m.group(2)
            result["delay_spread_ns"] = m.group(3)
            result["mobility_mps"] = m.group(4)
            return result

    model_id = option_value(text, ["vrtsim.cirdb_model_id", "cirdb_model_id"])
    delay_spread = option_value(text, ["vrtsim.cirdb_ds_ns", "cirdb_ds_ns"])
    mobility = option_value(text, ["vrtsim.cirdb_speed_mps", "cirdb_speed_mps"])
    model = tdl_name(model_id)
    if model:
        result["channel_model_id"] = model_id
        result["channel_model"] = model
    if delay_spread:
        result["delay_spread_ns"] = delay_spread
    if mobility:
        result["mobility_mps"] = mobility

    legacy = first_match(r'channel[_ -]?model\s*[=:]\s*([^"\s,]+)', text)
    if legacy and legacy.lower() != "vrtsim":
        result["channel_model"] = legacy

    if not result["channel_model"] and "vrtsim" in text.lower():
        result["channel_model"] = "TDL-A"
        result["channel_model_id"] = result["channel_model_id"] or "0"
        result["delay_spread_ns"] = result["delay_spread_ns"] or "10.0"
        result["mobility_mps"] = result["mobility_mps"] or "1.5"
    return result


def ensure(row, key, value):
    if not row.get(key):
        row[key] = str(value)


def replace_placeholder(row, key, value):
    current = row.get(key, "")
    if value and (not current or current.lower() in ("vrtsim", "not_logged")):
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
    ue_ips = set(re.findall(r"UE IPv4:\s*([0-9.]+)", ue_log))
    ue_ids = set(re.findall(r"\[UE\s+(\d+)\]", ue_log))
    tun_ids = set(re.findall(r"TUN Interface\s+oaitun_ue(\d+)", ue_log))

    ensure(row, "ue_count", len(ue_ips) or len(tun_ids) or len(ue_ids) or (1 if ue_log.strip() else 0))
    channel_context = vrtsim_channel_context(all_logs)
    replace_placeholder(row, "channel_model", channel_context["channel_model"] or "not_logged")
    ensure(row, "channel_model_id", channel_context["channel_model_id"])
    ensure(row, "delay_spread_ns", channel_context["delay_spread_ns"])
    ensure(row, "mobility_mps", channel_context["mobility_mps"])
    ensure(row, "path_loss_db", channel_context["path_loss_db"])
    ensure(row, "noise_power_sample", channel_context["noise_power_sample"])

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
    ensure(row, "snr_samples", len(snrs))
    ensure(row, "snr_db_avg", f"{statistics.mean(snrs):.3f}" if snrs else "")
    ensure(row, "snr_db_min", f"{min(snrs):.3f}" if snrs else "")
    ensure(row, "snr_db_max", f"{max(snrs):.3f}" if snrs else "")
    row["snr_triplet"] = f"{row.get('snr_db_avg', '')}/{row.get('snr_db_min', '')}/{row.get('snr_db_max', '')}" if row.get("snr_db_avg") else "n/a"
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
    out.write("| IQ width | compMeth | status | UE # | FH UL/DL/Total Mbps | User iperf3 UL/DL Mbps |\n")
    out.write("|---:|---:|---|---:|---:|---:|\n")
    for r in rows:
        out.write("| {iq_width} | {comp_method} | {status} | {ue_count} | {fh_rx_mbps_avg}/{fh_tx_mbps_avg}/{fh_total_mbps_avg} | {iperf_ul_mbps}/{iperf_dl_mbps} |\n".format(**r))
    out.write("\n## Radio Context\n\n")
    if rows:
        r = rows[0]
        out.write(f"- Carrier: `{r.get('carrier_hz', '')}` Hz\n")
        out.write(f"- Bandwidth/RB: tx/rx `{r.get('tx_bw_prb', '')}/{r.get('rx_bw_prb', '')}` PRB, dl/ul `{r.get('dl_rb', '')}/{r.get('ul_rb', '')}` RB\n")
        out.write(f"- Numerology: `{r.get('numerology', '')}`\n")
        out.write(f"- Antennas: tx/rx `{r.get('nb_tx', '')}/{r.get('nb_rx', '')}`\n")
        out.write("- Channel model: {} (model id {})\n".format(r.get("channel_model", ""), r.get("channel_model_id", "")))
        out.write("- Delay spread: {} ns\n".format(r.get("delay_spread_ns", "")))
        out.write("- Mobility: {} m/s\n".format(r.get("mobility_mps", "")))
        out.write("- VRTSIM path loss: {} dB (`n/a` for CIRDB/taps unless gain is embedded in taps)\n".format(r.get("path_loss_db") or "n/a"))
        out.write("- VRTSIM noise power: {} sample value (`0` means no configured global noise in current logs)\n".format(r.get("noise_power_sample") or "n/a"))
        out.write("\n| IQ width | DU post-combining SNR avg/min/max dB | FH max Mbps | FH samples | trial dir |\n")
        out.write("|---:|---|---:|---:|---|\n")
        for r in rows:
            out.write("| {iq_width} | {snr_triplet} | {fh_total_mbps_max} | {fh_samples} | `{trial_dir}` |\n".format(**r))
    out.write("\n## Notes\n\n")
    out.write("- `compMeth=0` is uncompressed / `XRAN_COMPMETHOD_NONE`.\n")
    out.write("- `compMeth=1` is block-floating compression / `XRAN_COMPMETHOD_BLKFLOAT`.\n")
    out.write("- FH UL/DL/Total is reported as parsed rx/tx/total average Mbps after dropping the first warmup samples.\n")
    out.write("- DU SNR is the post-combining PHY estimate parsed from `ULSCH ... trace` lines; it is not a configured vrtsim input/channel SNR.\n")
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
  write_csv_header
  log "output: ${OUT_DIR}"
  log "widths: ${WIDTHS}"
  log "iperf: direction=${IPERF_DIRECTION} protocol=${IPERF_PROTOCOL} bitrate=${IPERF_BITRATE} server=${IPERF_SERVER}:${IPERF_PORT} seconds=${IPERF_SECONDS} parallel=${IPERF_PARALLEL}"

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
