#!/usr/bin/env bash
#
# BIMCraft Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      BIMCraft – Open-Source-BIM (Revit-Workflow) in pure Rust (Desktop/egui)
# Upstream: https://github.com/IPedrax/BIMCraft
# Stack:    Offizielles Linux-.deb (v0.7.0) + Xvfb + openbox + x11vnc + noVNC
# Laeuft:   vollstaendig lokal im LXC; keine Cloud-Dienste zur Laufzeit
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
#
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BIM-CRAFT-Proxmox/main/install/bimcraft.sh)"
#   CTID=150 CORES=4 RAM=6144 DISK=16 bash -c "$(wget -qLO - .../install/bimcraft.sh)"
#   bash bimcraft.sh --ctid 150 --cores 4 --memory 6144 --disk 16 --debug
#
# Browser-UI nach der Installation: http://<CT-IP>:6080/vnc.html
#
set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="bimcraft"                                   # Container-Hostname + Service-Prefix
APP_DISPLAY="BIMCraft"
APP_VERSION="${BIMCRAFT_VERSION:-0.7.0}"         # Release-Tag ohne "v"
UPSTREAM_REPO="https://github.com/IPedrax/BIMCraft"
INSTALLER_REPO="https://github.com/HatchetMan111/BIM-CRAFT-Proxmox"
WEB_PORT="${BIMCRAFT_WEB_PORT:-6080}"            # noVNC
VNC_PORT="${BIMCRAFT_VNC_PORT:-5900}"            # x11vnc, nur localhost

DEFAULT_CORES="4"                                # vCPU (Software-Rendering)
DEFAULT_RAM="6144"                               # RAM in MB
DEFAULT_SWAP="2048"                              # Swap in MB
DEFAULT_DISK="16"                                # Disk in GB
MIN_CORES="2"
MIN_RAM="3072"
MIN_DISK="12"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"
DEFAULT_OS="debian-12-standard"
UNPRIVILEGED="1"
FEATURES="nesting=1"

CT_ID_ARG="${CTID:-${CT_ID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
SWAP_ARG="${SWAP:-$DEFAULT_SWAP}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS=("$@")

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

die() { msg_error "$*"; exit 1; }

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"

usage() {
  cat <<EOF
${APP_DISPLAY} Proxmox LXC Installer (Community-Scripts-Stil)

Usage:
  bash ${APP}.sh [OPTIONEN]
  CTID=150 bash ${APP}.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/raw/main/install/${APP}.sh)" _ --ctid 150

Optionen:
  --ctid ID            Container-ID (Default: naechste freie via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES}, Minimum ${MIN_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum ${MIN_RAM})
  --swap MB            Swap in MB (Default: ${DEFAULT_SWAP})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK}, Minimum ${MIN_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --ip CIDR            statische IP, z.B. 192.168.1.50/24 (Default: dhcp)
  --gateway IP         Gateway bei statischer IP
  --nameserver IP      DNS-Server im Container (Default: Host-DNS, sonst 1.1.1.1)
  --password PW        Root-Passwort (Default: zufaellig, wird angezeigt)
  --ssh-key PATH       SSH-Public-Key in den Container uebernehmen (optional)
  --novnc-password PW  noVNC-Passwort vorgeben (Default: zufaellig/beibehalten)
  --reset-password     Neues zufaelliges noVNC-Passwort erzeugen
  --app-version VER    BIMCraft-Release (Default: ${APP_VERSION})
  --update             Vorhandenen Container neu provisionieren
  --uninstall          Container stoppen und zerstoeren (bestaetigen oder --yes)
  --yes                Bestaetigung fuer --uninstall ueberspringen
  --force              Hostname-Schutz bei --ctid/--uninstall deaktivieren
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe

Nach der Installation:
  Web UI: http://<LXC-IP>:${WEB_PORT}/vnc.html
  Log:    ${LOG_FILE}
EOF
}

# ---------------------------------------------------------------------------
# Vollstaendige Fehlermeldungskette (Stacktrace, Kontext, Logs)
# ---------------------------------------------------------------------------
redact_secrets() {
  local text="$*"
  [[ -n "${ROOT_PASSWORD:-}" ]] && text="${text//"$ROOT_PASSWORD"/***}"
  [[ -n "${NOVNC_PASSWORD_ARG:-}" ]] && text="${text//"$NOVNC_PASSWORD_ARG"/***}"
  printf '%s' "$text"
}

on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  trap - ERR
  set +e
  cmd="$(redact_secrets "$cmd")"
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}... [gekuerzt, vollstaendig in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $(redact_secrets "${SCRIPT_ARGS[*]}")"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Aufrufstapel (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i" >/dev/null 2>&1; do
    caller "$i" || true
    ((i++)) || true
  done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]] && pct status "$CTID" >/dev/null 2>&1; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- /etc/resolv.conf im Container ---"
    pct exec "${CTID}" -- cat /etc/resolv.conf 2>&1 || true
    echo ""
    msg_error "--- getent ahostsv4 deb.debian.org im Container ---"
    pct exec "${CTID}" -- getent ahostsv4 deb.debian.org 2>&1 || true
    echo ""
    msg_error "--- ping 1.1.1.1 im Container ---"
    pct exec "${CTID}" -- ping -c 2 -W 3 1.1.1.1 2>&1 || true
    local unit
    for unit in bimcraft-xvfb bimcraft-app bimcraft-vnc bimcraft-web; do
      msg_error "--- systemctl status ${unit} ---"
      pct exec "${CTID}" -- systemctl status "${unit}" --no-pager --full 2>&1 || true
      echo ""
      msg_error "--- journalctl -u ${unit} (letzte 80 Zeilen) ---"
      pct exec "${CTID}" -- journalctl -u "${unit}" --no-pager -n 80 2>&1 || true
      echo ""
    done
    msg_error "--- HTTP-Check im Container ---"
    pct exec "${CTID}" -- curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>&1 || true
    echo ""
    msg_error "--- Provision-Log (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- tail -n 100 /var/log/bimcraft-provision.log 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  msg_error "  bash -x ${APP}.sh $(redact_secrets "${SCRIPT_ARGS[*]}")"
  msg_error "  oder: DEBUG=1 bash ${APP}.sh $(redact_secrets "${SCRIPT_ARGS[*]}")"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
SWAP="$SWAP_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY_ARG=""
NOVNC_PASSWORD_ARG=""
RESET_PASSWORD="0"
IPCFG="dhcp"
GATEWAY=""
DNS_SERVER="${DNS_SERVER:-}"
UPDATE_ONLY="0"
UNINSTALL="0"
ASSUME_YES="0"
FORCE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)             CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)         HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)            CORES="${2:?--cores braucht einen Wert}"; shift 2 ;;
    --memory|--ram)     RAM="${2:?--memory braucht einen Wert}"; shift 2 ;;
    --swap)             SWAP="${2:?--swap braucht einen Wert}"; shift 2 ;;
    --disk)             DISK="${2:?--disk braucht einen Wert}"; shift 2 ;;
    --storage)          STORAGE_ARG="${2:?--storage braucht einen Wert}"; shift 2 ;;
    --template-store)   TEMPLATE_STORE="${2:?--template-store braucht einen Wert}"; shift 2 ;;
    --bridge)           BRIDGE="${2:?--bridge braucht einen Wert}"; shift 2 ;;
    --ip)               IPCFG="${2:?--ip braucht einen Wert}"; shift 2 ;;
    --gateway|--gw)     GATEWAY="${2:?--gateway braucht einen Wert}"; shift 2 ;;
    --nameserver|--dns) DNS_SERVER="${2:?--nameserver braucht einen Wert}"; shift 2 ;;
    --password)         ROOT_PASSWORD="${2:?--password braucht einen Wert}"; shift 2 ;;
    --ssh-key)          SSH_KEY_ARG="${2:?--ssh-key braucht einen Wert}"; shift 2 ;;
    --novnc-password)   NOVNC_PASSWORD_ARG="${2:?--novnc-password braucht einen Wert}"; shift 2 ;;
    --reset-password)   RESET_PASSWORD="1"; shift ;;
    --app-version)      APP_VERSION="${2:?--app-version braucht einen Wert}"; shift 2 ;;
    --update)           UPDATE_ONLY="1"; shift ;;
    --uninstall)        UNINSTALL="1"; shift ;;
    --yes|-y)           ASSUME_YES="1"; shift ;;
    --force)            FORCE="1"; shift ;;
    --debug|-x)         DEBUG="1"; shift ;;
    --help|-h)          usage; exit 0 ;;
    _)                  shift ;;  # Platzhalter fuer Einzeiler-Trick: ...)" _ --flags
    *)                  msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

if [[ "$DEBUG" == "1" ]]; then
  echo "--- DEBUG: set -x aktiv ---"
  set -x
fi

# ---------------------------------------------------------------------------
# Validierung
# ---------------------------------------------------------------------------
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

detect_nameserver() {
  local ns=""
  ns="$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf 2>/dev/null \
    | grep -vE '^(127\.|::1$)' | head -n1 || true)"
  if [[ -z "$ns" ]] && command -v resolvectl >/dev/null 2>&1; then
    ns="$(resolvectl status 2>/dev/null \
      | awk '/DNS Servers:/{for (i = 3; i <= NF; i++) print $i}' \
      | grep -vE '^(127\.|::1$)' | head -n1 || true)"
  fi
  printf '%s' "${ns:-1.1.1.1}"
}

[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren (sudo -i)."
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – laeuft das Script auf einem Proxmox-VE-Host?"

if [[ "$UNINSTALL" != "1" ]]; then
  for bin in pvesh pvesm pveam curl; do
    command -v "$bin" >/dev/null 2>&1 || die "Benoetigtes Tool fehlt: $bin"
  done
  [[ "$(uname -m)" == "x86_64" ]] || die "Dieses Script unterstuetzt nur x86_64 (gefunden: $(uname -m))."
fi

is_uint "$CORES" || die "--cores muss eine Zahl sein (gefunden: $CORES)"
is_uint "$RAM"   || die "--memory muss eine Zahl sein (gefunden: $RAM)"
is_uint "$SWAP"  || die "--swap muss eine Zahl sein (gefunden: $SWAP)"
is_uint "$DISK"  || die "--disk muss eine Zahl sein (gefunden: $DISK)"
if [[ -n "$CTID" ]]; then
  is_uint "$CTID" || die "--ctid muss eine Zahl sein (gefunden: $CTID)"
fi

for port_var in WEB_PORT VNC_PORT; do
  port_val="${!port_var}"
  if ! is_uint "$port_val" || (( port_val < 1 || port_val > 65535 )); then
    die "Ungueltiger Port fuer $port_var: $port_val"
  fi
done
(( WEB_PORT != VNC_PORT )) || die "WEB_PORT und VNC_PORT muessen unterschiedlich sein."

if [[ -n "$DNS_SERVER" ]]; then
  [[ "$DNS_SERVER" =~ ^[0-9a-fA-F:.]+$ ]] || die "--nameserver ungueltig: $DNS_SERVER"
fi
[[ -n "$DNS_SERVER" ]] || DNS_SERVER="$(detect_nameserver)"
MIRROR_IPS=""

if [[ "$UNINSTALL" != "1" ]]; then
  (( CORES >= MIN_CORES )) || die "vCPU zu klein: $CORES (Minimum $MIN_CORES, empfohlen $DEFAULT_CORES)."
  (( RAM >= MIN_RAM ))     || die "RAM zu klein: ${RAM} MB (Minimum ${MIN_RAM} MB, empfohlen ${DEFAULT_RAM} MB)."
  (( DISK >= MIN_DISK ))   || die "Disk zu klein: ${DISK} GB (Minimum ${MIN_DISK} GB, empfohlen ${DEFAULT_DISK} GB)."
  if (( CORES < DEFAULT_CORES )); then
    msg_warn "Weniger als ${DEFAULT_CORES} vCPU: Software-Rendering wird traege."
  fi
  if (( RAM < DEFAULT_RAM )); then
    msg_warn "Weniger als ${DEFAULT_RAM} MB RAM: grosse Modelle koennen OOM werden."
  fi
fi

if [[ "$IPCFG" != "dhcp" ]]; then
  IPCFG="${IPCFG#ip=}"
  [[ "$IPCFG" == */* ]] || IPCFG="${IPCFG}/24"
  [[ "$IPCFG" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "--ip ungueltig: '$IPCFG' (erwartet: dhcp oder 192.168.1.50/24)."
  [[ -n "$GATEWAY" ]] || msg_warn "Statische IP ohne --gateway – Route ggf. unvollstaendig."
elif [[ -n "$GATEWAY" ]]; then
  msg_warn "--gateway wird ohne statische --ip ignoriert."
  GATEWAY=""
fi

if [[ -n "$SSH_KEY_ARG" && ! -r "$SSH_KEY_ARG" ]]; then
  die "--ssh-key: Datei nicht lesbar: $SSH_KEY_ARG"
fi

gen_password() {
  local length="$1" out="" chars="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789" i
  for ((i = 0; i < length; i++)); do
    out+="${chars:RANDOM%${#chars}:1}"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Container finden / anlegen
# ---------------------------------------------------------------------------
CTID="${CTID//[[:space:]]/}"
REUSE="0"
CT_IP=""
TEMPLATE_VOLID=""
STORAGE=""
ROOT_PASSWORD_GENERATED="0"

find_existing_ct() {
  local id host
  while read -r id; do
    [[ -n "$id" ]] || continue
    host="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')"
    if [[ "$host" == "$HOSTNAME_ARG" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(pct list | awk 'NR>1 {print $1}')
  return 1
}

resolve_ctid() {
  if [[ -n "$CTID" ]]; then
    if pct status "$CTID" >/dev/null 2>&1; then
      local existing_host
      existing_host="$(pct config "$CTID" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')"
      if [[ "$existing_host" != "$HOSTNAME_ARG" && "$FORCE" != "1" ]]; then
        die "CT $CTID existiert mit Hostname '${existing_host:-<leer>}', erwartet '${HOSTNAME_ARG}'. Abbruch, um keinen fremden Container zu ueberschreiben. Nutze --hostname '${existing_host}' oder --force."
      fi
      REUSE="1"
      msg_info "Verwende vorhandenen Container CT $CTID (Update/Idempotenz)."
    else
      REUSE="0"
    fi
    return 0
  fi
  if CTID="$(find_existing_ct)"; then
    REUSE="1"
    msg_info "Vorhandener Container '${HOSTNAME_ARG}' gefunden: CT $CTID."
  else
    CTID="$(pvesh get /cluster/nextid | tr -d '[:space:]"')"
    [[ -n "$CTID" ]] || die "Konnte keine freie CT-ID ermitteln."
    REUSE="0"
    msg_info "Naechste freie CT-ID: $CTID"
  fi
}

# ---------------------------------------------------------------------------
# Storage / Template
# ---------------------------------------------------------------------------
resolve_storage() {
  local detected
  if [[ -n "$STORAGE_ARG" ]]; then
    STORAGE="$STORAGE_ARG"
    return 0
  fi
  local storage_list
  storage_list="$(pvesm status -content rootdir 2>/dev/null || true)"
  if awk 'NR>1 && $1 == "local-lvm" { found=1 } END { exit !found }' <<<"$storage_list"; then
    STORAGE="local-lvm"
  else
    detected="$(awk 'NR>1 {print $1}' <<<"$storage_list" | head -n1)"
    [[ -n "$detected" ]] || die "Kein Storage mit Content-Typ 'rootdir' gefunden. Bitte --storage setzen."
    STORAGE="$detected"
  fi
  msg_info "RootFS-Storage: $STORAGE"
}

ensure_template() {
  local avail
  TEMPLATE_VOLID="$(pveam list "$TEMPLATE_STORE" 2>/dev/null | awk -v pat="$DEFAULT_OS" '$1 ~ pat {print $1}' | sort -V | tail -n1)"
  if [[ -z "$TEMPLATE_VOLID" ]]; then
    msg_info "Lade Template ${DEFAULT_OS} nach ${TEMPLATE_STORE} ..."
    pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen – versuche Download trotzdem."
    avail="$(pveam available --section system 2>/dev/null | awk -v pat="$DEFAULT_OS" '$2 ~ pat {print $2}' | sort -V | tail -n1)"
    [[ -n "$avail" ]] || die "Kein Template '${DEFAULT_OS}' in pveam verfuegbar."
    pveam download "$TEMPLATE_STORE" "$avail"
    TEMPLATE_VOLID="$(pveam list "$TEMPLATE_STORE" | awk -v pat="$DEFAULT_OS" '$1 ~ pat {print $1}' | sort -V | tail -n1)"
  fi
  [[ -n "$TEMPLATE_VOLID" ]] || die "Template-Volume konnte nicht ermittelt werden."
  msg_info "Template: $TEMPLATE_VOLID"
}

create_ct() {
  local net="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
  local xtrace_was_on="0"
  if [[ -n "$GATEWAY" ]]; then
    net+=",gw=${GATEWAY}"
  fi
  msg_info "Erstelle CT $CTID (${CORES} vCPU / ${RAM} MB / ${SWAP} MB Swap / ${DISK} GB) ..."
  if [[ "$DEBUG" == "1" ]]; then
    xtrace_was_on="1"
    set +x
  fi
  pct create "$CTID" "$TEMPLATE_VOLID" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$net" \
    --nameserver "$DNS_SERVER" \
    --unprivileged "$UNPRIVILEGED" \
    --features "$FEATURES" \
    --onboot 1 \
    --password "$ROOT_PASSWORD" \
    --description "${APP_DISPLAY} ${APP_VERSION} – ${UPSTREAM_REPO} – installed by ${INSTALLER_REPO}"
  if [[ "$xtrace_was_on" == "1" ]]; then
    set -x
  fi
}

start_ct() {
  if [[ "$REUSE" == "1" ]]; then
    msg_info "Aktualisiere Konfiguration von CT $CTID ..."
    pct set "$CTID" --onboot 1 --cores "$CORES" --memory "$RAM" --swap "$SWAP" >/dev/null
    if [[ "$(pct status "$CTID" 2>/dev/null || true)" != *running* ]]; then
      pct start "$CTID"
    fi
  else
    create_ct
    pct start "$CTID"
  fi
}

wait_for_ip() {
  local i ip
  for i in $(seq 1 90); do
    ip="$(pct exec "$CTID" -- ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 { split($4, a, "/"); print a[1] }')" || true
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)" || true
    fi
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      CT_IP="$ip"
      msg_ok "Container-IP: $CT_IP"
      return 0
    fi
    sleep 2
  done
  pct exec "$CTID" -- ip addr 2>&1 || true
  pct config "$CTID" 2>&1 || true
  die "Container hat keine IPv4-Adresse erhalten (DHCP/Netzwerk pruefen)."
}

container_dns_ok() {
  pct exec "$CTID" -- bash -c 'timeout 5 getent ahostsv4 deb.debian.org >/dev/null 2>&1 && timeout 5 getent ahostsv4 github.com >/dev/null 2>&1'
}

ensure_dns() {
  local i
  pct set "$CTID" --nameserver "$DNS_SERVER" >/dev/null 2>&1 \
    || msg_warn "pct set --nameserver fehlgeschlagen; setze /etc/resolv.conf direkt."
  if container_dns_ok; then
    msg_ok "DNS im Container funktioniert (Nameserver ${DNS_SERVER})."
    return 0
  fi
  msg_warn "DNS im Container defekt – setze Nameserver ${DNS_SERVER} ..."
  pct exec "$CTID" -- bash -c '
    {
      printf "nameserver %s\n" "$1"
      [[ "$1" == "1.1.1.1" ]] || printf "nameserver 1.1.1.1\n"
      [[ "$1" == "9.9.9.9" ]] || printf "nameserver 9.9.9.9\n"
    } > /etc/resolv.conf
  ' _ "$DNS_SERVER" || die "Konnte /etc/resolv.conf im Container nicht schreiben."
  for i in $(seq 1 30); do
    if container_dns_ok; then
      msg_ok "DNS im Container funktioniert (Nameserver ${DNS_SERVER})."
      return 0
    fi
    sleep 2
  done
  msg_error "--- /etc/resolv.conf im Container ---"
  pct exec "$CTID" -- cat /etc/resolv.conf 2>&1 || true
  msg_error "--- getent ahostsv4 deb.debian.org ---"
  pct exec "$CTID" -- getent ahostsv4 deb.debian.org 2>&1 || true
  die "DNS im Container nicht erreichbar (Nameserver ${DNS_SERVER}, deb.debian.org)."
}

resolve_mirror_ips() {
  local host ip
  MIRROR_IPS=""
  # github.com allein reicht nicht: Release-Downloads werden zu diesen
  # CDN-Hosts weitergeleitet und brauchen ebenfalls einen Pin.
  for host in deb.debian.org security.debian.org github.com \
              objects.githubusercontent.com release-assets.githubusercontent.com; do
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    [[ -n "$ip" ]] || return 1
    MIRROR_IPS+="${host}=${ip} "
  done
  return 0
}

install_ssh_key() {
  [[ -n "$SSH_KEY_ARG" ]] || return 0
  pct exec "$CTID" -- mkdir -p /root/.ssh
  pct exec "$CTID" -- chmod 700 /root/.ssh
  pct push "$CTID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys --perms 0600
  msg_ok "SSH-Key installiert."
}

# ---------------------------------------------------------------------------
# Provision-Script (laeuft IM Container)
# ---------------------------------------------------------------------------
write_provision_script() {
  cat >"$PROVISION_TMP" <<'PROVISION_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_USER="bimcraft"
APP_HOME="/home/bimcraft"
APP_VERSION="${BIMCRAFT_VERSION:?BIMCRAFT_VERSION fehlt}"
NOVNC_PASSWORD="${BIMCRAFT_NOVNC_PASSWORD:-}"
RESET_PASSWORD="${BIMCRAFT_RESET_PASSWORD:-0}"
DEBUG="${BIMCRAFT_DEBUG:-0}"
WEB_PORT="${BIMCRAFT_WEB_PORT:-6080}"
VNC_PORT="${BIMCRAFT_VNC_PORT:-5900}"
DNS_SERVER="${BIMCRAFT_DNS:-}"
MIRROR_IPS="${BIMCRAFT_MIRROR_IPS:-}"
LOG_FILE="/var/log/bimcraft-provision.log"

mkdir -p /var/log
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

msg_info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m    $*"; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
die() { msg_error "$*"; exit 1; }

on_error() {
  local exit_code="$1" lineno="$2" cmd="$3" safe_cmd
  trap - ERR
  set +e
  safe_cmd="$cmd"
  [[ -n "${PASSWORD:-}" ]] && safe_cmd="${safe_cmd//"$PASSWORD"/***}"
  [[ -n "${NOVNC_PASSWORD:-}" ]] && safe_cmd="${safe_cmd//"$NOVNC_PASSWORD"/***}"
  echo ""
  msg_error "════════ PROVISIONIERUNG IM CONTAINER FEHLGESCHLAGEN ════════"
  msg_error "Befehl    : $safe_cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Stack     : ${FUNCNAME[*]:-main}"
  msg_error "Logdatei  : $LOG_FILE"
  echo ""
  for unit in bimcraft-xvfb bimcraft-app bimcraft-vnc bimcraft-web; do
    msg_error "--- systemctl status $unit ---"
    systemctl status "$unit" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl -u $unit (letzte 80 Zeilen) ---"
    journalctl -u "$unit" --no-pager -n 80 2>&1 || true
    echo ""
  done
  msg_error "--- failed units ---"
  systemctl --failed --no-pager 2>&1 || true
  echo ""
  msg_error "--- HTTP-Check ---"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>&1 || true
  echo ""
  msg_error "Vollstaendiges Log: $LOG_FILE"
  exit "$exit_code"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

if [[ "$DEBUG" == "1" ]]; then
  echo "--- DEBUG: set -x aktiv (Container) ---"
  set -x
fi

gen_password() {
  local length="$1" out="" chars="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789" i
  for ((i = 0; i < length; i++)); do
    out+="${chars:RANDOM%${#chars}:1}"
  done
  printf '%s' "$out"
}

export DEBIAN_FRONTEND=noninteractive

container_dns_ok() {
  timeout 5 getent ahostsv4 deb.debian.org >/dev/null 2>&1 \
    && timeout 5 getent ahostsv4 github.com >/dev/null 2>&1
}

write_resolv_conf() {
  local ns="${DNS_SERVER:-1.1.1.1}"
  {
    printf 'nameserver 1.1.1.1\n'
    [[ "$ns" == "1.1.1.1" ]] || printf 'nameserver %s\n' "$ns"
    [[ "$ns" == "9.9.9.9" ]] || printf 'nameserver 9.9.9.9\n'
  } > /etc/resolv.conf
}

apply_mirror_hosts() {
  [[ -n "$MIRROR_IPS" ]] || return 0
  local pair host ip
  # /etc/hosts ist in LXC ein Bind-Mount: mv/sed -i (Rename) schlagen fehl,
  # deshalb in-place schreiben statt Datei zu ersetzen.
  grep -v "# bimcraft-mirror-pin" /etc/hosts > /tmp/bimcraft-hosts.tmp 2>/dev/null || true
  for pair in $MIRROR_IPS; do
    host="${pair%%=*}"; ip="${pair#*=}"
    echo "${ip} ${host} # bimcraft-mirror-pin" >> /tmp/bimcraft-hosts.tmp
  done
  cat /tmp/bimcraft-hosts.tmp > /etc/hosts
  rm -f /tmp/bimcraft-hosts.tmp
  msg_ok "Mirror-Hostnames in /etc/hosts gepinnt (bypasses Container-DNS)."
}

repair_container_dns() {
  local i ns="${DNS_SERVER:-1.1.1.1}"
  msg_warn "DNS im Container defekt – schreibe Nameserver ${ns} und Fallbacks ..."
  write_resolv_conf
  for i in $(seq 1 15); do
    if container_dns_ok; then
      msg_ok "DNS im Container funktioniert (Nameserver ${ns})."
      return 0
    fi
    sleep 2
  done
  msg_error "--- /etc/resolv.conf ---"
  cat /etc/resolv.conf >&2 || true
  msg_error "--- getent ahostsv4 deb.debian.org ---"
  getent ahostsv4 deb.debian.org >&2 || true
  msg_error "--- ping 1.1.1.1 (Netzwerk-Test) ---"
  ping -c 2 -W 2 1.1.1.1 >&2 || true
  die "DNS im Container nicht erreichbar (Nameserver ${ns}, deb.debian.org)."
}

ensure_container_dns() {
  if container_dns_ok; then
    msg_ok "DNS im Container funktioniert (Nameserver ${DNS_SERVER:-auto})."
    return 0
  fi
  repair_container_dns
}

resolve_mirror_ips_in_container() {
  # Fallback, wenn die Host-seitige Aufloesung leer geblieben ist: der
  # Container loest die Mirror-Hosts selbst auf (DNS-Check ist zu dem
  # Zeitpunkt gerade bestanden) und pinnt sie in /etc/hosts. Damit wird
  # apt von DNS-Transientfehlern waehrend der Paket-Downloads entkoppelt.
  local host ip attempt
  for attempt in 1 2 3; do
    MIRROR_IPS=""
    for host in deb.debian.org security.debian.org github.com \
                objects.githubusercontent.com release-assets.githubusercontent.com; do
      ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
      [[ -n "$ip" ]] || { MIRROR_IPS=""; break; }
      MIRROR_IPS+="${host}=${ip} "
    done
    [[ -n "$MIRROR_IPS" ]] && return 0
    sleep 2
  done
  return 1
}

apt_update() {
  apt-get -qq -o Acquire::ForceIPv4=true -o Acquire::Retries=10 -o Acquire::http::Timeout=20 update
}

apt_install() {
  apt-get install -y --no-install-recommends \
    -o Acquire::ForceIPv4=true -o Acquire::Retries=10 -o Acquire::http::Timeout=20 "$@"
}

ensure_container_dns

if [[ -z "$MIRROR_IPS" ]] && resolve_mirror_ips_in_container; then
  msg_ok "Mirror-IPs im Container aufgeloest: ${MIRROR_IPS% }"
elif [[ -z "$MIRROR_IPS" ]]; then
  msg_warn "Konnte Mirror-IPs im Container nicht aufloesen – fahre ohne /etc/hosts-Pinning fort."
  MIRROR_IPS=""
fi
apply_mirror_hosts

msg_info "Installiere Systemabhaengigkeiten ..."
for attempt in 1 2 3; do
  if apt_update; then break; fi
  if (( attempt == 3 )); then
    die "apt-get update fehlgeschlagen (DNS/Netzwerk pruefen)."
  fi
  msg_warn "apt-get update Versuch ${attempt}/3 fehlgeschlagen – DNS/Netzwerk reparieren ..."
  repair_container_dns
  sleep 5
done
for attempt in 1 2 3; do
  if apt_install \
    ca-certificates curl xz-utils iproute2 \
    xvfb x11vnc novnc websockify openbox x11-utils \
    libgl1 libglx-mesa0 libegl1 libegl-mesa0 libgl1-mesa-dri \
    libxkbcommon0 libx11-6 libxcb1 libxcb-render0 libxcb-shape0 libxcb-xfixes0 \
    libxcursor1 libxrandr2 libxi6 libxrender1 libxext6 \
    fonts-dejavu-core; then
    break
  fi
  if (( attempt == 3 )); then
    die "apt-get install fehlgeschlagen (DNS/Netzwerk pruefen)."
  fi
  msg_warn "apt-get install Versuch ${attempt}/3 fehlgeschlagen – DNS/Netzwerk reparieren ..."
  repair_container_dns
  sleep 5
done
msg_ok "Systempakete installiert."

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  die "Container-Architektur ist $(dpkg --print-architecture), erwartet amd64/x86_64."
fi

msg_info "Lade ${APP_DISPLAY:-BIMCraft} ${APP_VERSION} von GitHub Releases ..."
DEB="bimcraft-${APP_VERSION}-linux-x86_64.deb"
BASE_URL="https://github.com/IPedrax/BIMCraft/releases/download/v${APP_VERSION}"
CACHE_DIR="/var/cache/bimcraft"
install -d -m 0755 "$CACHE_DIR"
cd "$CACHE_DIR"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$DEB" "${BASE_URL}/${DEB}"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o SHA256SUMS "${BASE_URL}/SHA256SUMS"
checksum_line="$(awk -v f="$DEB" '{ name=$2; sub(/^\*/, "", name); if (name == f) print }' SHA256SUMS)"
[[ -n "$checksum_line" ]] || die "Kein SHA256-Eintrag fuer ${DEB} in SHA256SUMS gefunden."
printf '%s\n' "$checksum_line" | sha256sum -c -
msg_ok "SHA-256 geprueft."

apt-get install -y "./${DEB}"
msg_ok "BIMCraft installiert: $(dpkg-query -W -f='${Version}' bimcraft)."

if ! getent passwd "$APP_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
fi
install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$APP_HOME" "$APP_HOME/Projects"

install -d -m 0755 /etc/bimcraft
xtrace_was_on="0"
if [[ "$DEBUG" == "1" ]]; then
  xtrace_was_on="1"
  set +x
fi
PASSWORD=""
if [[ -n "$NOVNC_PASSWORD" ]]; then
  PASSWORD="$NOVNC_PASSWORD"
elif [[ "$RESET_PASSWORD" == "1" ]]; then
  PASSWORD="$(gen_password 12)"
elif [[ -s /root/bimcraft-novnc-password ]]; then
  PASSWORD="$(cat /root/bimcraft-novnc-password)"
else
  PASSWORD="$(gen_password 12)"
fi
[[ -n "$PASSWORD" ]] || PASSWORD="$(gen_password 12)"
printf '%s' "$PASSWORD" >/root/bimcraft-novnc-password
chmod 600 /root/bimcraft-novnc-password
umask 077
x11vnc -storepasswd "$PASSWORD" /etc/bimcraft/vnc.pass >/dev/null
chmod 600 /etc/bimcraft/vnc.pass
chown "$APP_USER:$APP_USER" /etc/bimcraft/vnc.pass
if [[ "$xtrace_was_on" == "1" ]]; then
  set -x
fi
msg_ok "noVNC-Passwort gesetzt."

cat >/usr/local/bin/bimcraft-session <<'SESSION'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -r /etc/default/bimcraft ]]; then
  # shellcheck disable=SC1091
  . /etc/default/bimcraft
fi
openbox >/dev/null 2>&1 &
app_args=()
if [[ -n "${BIMCRAFT_ARGS:-}" ]]; then
  read -r -a app_args <<< "$BIMCRAFT_ARGS"
fi
exec /usr/bin/bimcraft "${app_args[@]}"
SESSION
chmod 0755 /usr/local/bin/bimcraft-session

if [[ ! -f /etc/default/bimcraft ]]; then
  printf 'BIMCRAFT_ARGS="--sample"\n' >/etc/default/bimcraft
fi
chmod 0644 /etc/default/bimcraft

cat >/etc/systemd/system/bimcraft-xvfb.service <<'UNIT_XVFB'
[Unit]
Description=BIMCraft Xvfb display :99
Documentation=https://github.com/IPedrax/BIMCraft
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bimcraft
Group=bimcraft
Environment=HOME=/home/bimcraft
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_XVFB

cat >/etc/systemd/system/bimcraft-app.service <<'UNIT_APP'
[Unit]
Description=BIMCraft desktop in Xvfb
Documentation=https://github.com/IPedrax/BIMCraft
After=network-online.target bimcraft-xvfb.service
Wants=network-online.target
Requires=bimcraft-xvfb.service

[Service]
Type=simple
User=bimcraft
Group=bimcraft
Environment=DISPLAY=:99
Environment=HOME=/home/bimcraft
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=GALLIUM_DRIVER=llvmpipe
Environment=WINIT_UNIX_BACKEND=x11
Environment=BIMCRAFT_NO_UPDATE_CHECK=1
Environment=XDG_RUNTIME_DIR=/run/bimcraft
RuntimeDirectory=bimcraft
RuntimeDirectoryMode=0700
ExecStart=/usr/local/bin/bimcraft-session
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_APP

cat >/etc/systemd/system/bimcraft-vnc.service <<'UNIT_VNC'
[Unit]
Description=BIMCraft x11vnc (localhost only)
Documentation=https://github.com/IPedrax/BIMCraft
After=network-online.target bimcraft-xvfb.service
Wants=network-online.target
Requires=bimcraft-xvfb.service

[Service]
Type=simple
User=bimcraft
Group=bimcraft
Environment=DISPLAY=:99
Environment=HOME=/home/bimcraft
ExecStart=/usr/bin/x11vnc -display :99 -rfbport 5900 -localhost -rfbauth /etc/bimcraft/vnc.pass -forever -shared -noxdamage -repeat -cursor arrow -quiet
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_VNC

cat >/etc/systemd/system/bimcraft-web.service <<'UNIT_WEB'
[Unit]
Description=BIMCraft noVNC web interface
Documentation=https://github.com/IPedrax/BIMCraft
After=network-online.target bimcraft-vnc.service
Wants=network-online.target
Requires=bimcraft-vnc.service

[Service]
Type=simple
User=bimcraft
Group=bimcraft
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_WEB

sed -i "s|0.0.0.0:6080|0.0.0.0:${WEB_PORT}|g; s|127.0.0.1:5900|127.0.0.1:${VNC_PORT}|g" \
  /etc/systemd/system/bimcraft-web.service
sed -i "s|-rfbport 5900|-rfbport ${VNC_PORT}|" \
  /etc/systemd/system/bimcraft-vnc.service

chmod 0644 /etc/systemd/system/bimcraft-xvfb.service \
  /etc/systemd/system/bimcraft-app.service \
  /etc/systemd/system/bimcraft-vnc.service \
  /etc/systemd/system/bimcraft-web.service

if command -v ufw >/dev/null 2>&1; then
  ufw_state="$(ufw status 2>/dev/null || true)"
  if [[ "$ufw_state" == *"Status: active"* ]]; then
    ufw allow "${WEB_PORT}/tcp" >/dev/null || true
    msg_ok "ufw: Port ${WEB_PORT}/tcp freigegeben."
  fi
fi

msg_info "Aktiviere und starte Services ..."
systemctl daemon-reload
systemctl enable bimcraft-xvfb.service bimcraft-app.service bimcraft-vnc.service bimcraft-web.service >/dev/null
systemctl restart bimcraft-xvfb.service
install -d -m 1777 /tmp/.X11-unix
for _ in $(seq 1 30); do
  [[ -S /tmp/.X11-unix/X99 ]] && break
  sleep 0.5
done
[[ -S /tmp/.X11-unix/X99 ]] || die "Xvfb-Socket /tmp/.X11-unix/X99 wurde nicht erstellt."
systemctl restart bimcraft-app.service
systemctl restart bimcraft-vnc.service
systemctl restart bimcraft-web.service

msg_info "Warte auf die Web-UI (max. 120 s) ..."
http_ok="0"
for _ in $(seq 1 60); do
  if vnc_html="$(curl -fsS "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>/dev/null || true)" && grep -qi 'noVNC' <<<"$vnc_html"; then
    http_ok="1"
    break
  fi
  sleep 2
done
[[ "$http_ok" == "1" ]] || die "noVNC antwortet nicht auf http://127.0.0.1:${WEB_PORT}/vnc.html (Port belegt oder websockify ausgefallen?)"
msg_ok "noVNC antwortet (HTTP 200)."

banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${VNC_PORT}; head -c 12 <&3" 2>/dev/null || true)"
[[ "$banner" == RFB* ]] || die "x11vnc sendet kein VNC-Banner auf 127.0.0.1:${VNC_PORT} (erhalten: '${banner}')."
msg_ok "VNC-Banner: ${banner}"

has_bimcraft_window() {
  local id
  while read -r id; do
    [[ -n "$id" ]] || continue
    if DISPLAY=:99 xprop -id "$id" WM_CLASS 2>/dev/null | grep -qi 'bimcraft'; then
      return 0
    fi
  done < <(DISPLAY=:99 xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o '0x[0-9a-fA-F]*' || true)
  return 1
}

window_ok="0"
for _ in $(seq 1 30); do
  if has_bimcraft_window; then
    window_ok="1"
    break
  fi
  sleep 2
done
if [[ "$window_ok" != "1" ]]; then
  DISPLAY=:99 xprop -root _NET_CLIENT_LIST 2>&1 || true
  die "Kein BIMCraft-Fenster in Xvfb :99 gefunden."
fi
msg_ok "BIMCraft-Fenster laeuft in Xvfb :99."
pgrep -u "$APP_USER" -x bimcraft >/dev/null || die "BIMCraft-Prozess laeuft nicht."
msg_ok "Provisionierung abgeschlossen."
PROVISION_SCRIPT
}

# ---------------------------------------------------------------------------
# Provisionierung ausfuehren
# ---------------------------------------------------------------------------
PROVISION_TMP="$(mktemp /tmp/bimcraft-provision.XXXXXX.sh)"
cleanup() { rm -f "$PROVISION_TMP"; }
trap 'cleanup' EXIT

provision_ct() {
  local xtrace_was_on="0"
  write_provision_script
  pct push "$CTID" "$PROVISION_TMP" /root/bimcraft-provision.sh --perms 0700
  msg_info "Provisioniere BIMCraft in CT $CTID ..."
  if [[ "$DEBUG" == "1" ]]; then
    xtrace_was_on="1"
    set +x
  fi
  pct exec "$CTID" -- env \
    "BIMCRAFT_VERSION=$APP_VERSION" \
    "BIMCRAFT_NOVNC_PASSWORD=$NOVNC_PASSWORD_ARG" \
    "BIMCRAFT_RESET_PASSWORD=$RESET_PASSWORD" \
    "BIMCRAFT_DEBUG=$DEBUG" \
    "BIMCRAFT_WEB_PORT=$WEB_PORT" \
    "BIMCRAFT_VNC_PORT=$VNC_PORT" \
    "BIMCRAFT_DNS=$DNS_SERVER" \
    "BIMCRAFT_MIRROR_IPS=$MIRROR_IPS" \
    bash /root/bimcraft-provision.sh
  if [[ "$xtrace_was_on" == "1" ]]; then
    set -x
  fi
}

# ---------------------------------------------------------------------------
# Verifikation auf dem Host
# ---------------------------------------------------------------------------
verify_unit_active() {
  local unit
  for unit in bimcraft-xvfb bimcraft-app bimcraft-vnc bimcraft-web; do
    if ! pct exec "$CTID" -- systemctl is-active --quiet "$unit"; then
      pct exec "$CTID" -- systemctl status "$unit" --no-pager -l 2>&1 || true
      pct exec "$CTID" -- journalctl -u "$unit" --no-pager -n 100 2>&1 || true
      die "Service ${unit} ist nicht aktiv."
    fi
  done
  msg_ok "Alle vier Services sind aktiv."
}

verify_http() {
  local i
  local html
  for i in $(seq 1 90); do
    if html="$(pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>/dev/null || true)" && grep -qi 'noVNC' <<<"$html"; then
      msg_ok "Web-UI antwortet (HTTP 200 auf localhost:${WEB_PORT}/vnc.html)."
      return 0
    fi
    sleep 2
  done
  pct exec "$CTID" -- curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>&1 || true
  die "Web-UI antwortet nicht oder liefert nicht die noVNC-Oberflaeche (Port ${WEB_PORT} evtl. belegt)."
}

verify_vnc_banner() {
  local banner
  banner="$(timeout 5 pct exec "$CTID" -- bash -c "exec 3<>/dev/tcp/127.0.0.1/${VNC_PORT}; head -c 12 <&3" 2>/dev/null || true)"
  [[ "$banner" == RFB* ]] || die "VNC-Banner fehlt auf 127.0.0.1:${VNC_PORT} (erhalten: '${banner}')."
  msg_ok "VNC-Banner: ${banner}"
}

verify_window() {
  local i
  for i in $(seq 1 30); do
    if pct exec "$CTID" -- bash -c 'for id in $(DISPLAY=:99 xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o "0x[0-9a-fA-F]*"); do DISPLAY=:99 xprop -id "$id" WM_CLASS 2>/dev/null | grep -qi bimcraft && exit 0; done; exit 1'; then
      msg_ok "BIMCraft-Fenster im Xvfb gefunden."
      return 0
    fi
    sleep 2
  done
  pct exec "$CTID" -- env DISPLAY=:99 xprop -root _NET_CLIENT_LIST 2>&1 || true
  die "Kein BIMCraft-Fenster im Xvfb gefunden."
}

verify_onboot() {
  local ct_config
  ct_config="$(pct config "$CTID")"
  grep -q '^onboot: 1$' <<<"$ct_config" || die "onboot ist fuer CT $CTID nicht gesetzt."
  msg_ok "onboot: 1 ist gesetzt."
}

verify_installation() {
  verify_unit_active
  verify_http
  verify_vnc_banner
  verify_window
  verify_onboot
}

# ---------------------------------------------------------------------------
# Ausgabe / Credentials
# ---------------------------------------------------------------------------
print_summary() {
  local novnc_password credentials_file
  novnc_password="$(pct exec "$CTID" -- cat /root/bimcraft-novnc-password 2>/dev/null || true)"
  credentials_file="/root/bimcraft-${CTID}-credentials.txt"
  {
    echo "BIMCraft – CT $CTID"
    echo "URL: http://${CT_IP}:${WEB_PORT}/vnc.html"
    echo "noVNC-Passwort: ${novnc_password}"
    if [[ "$ROOT_PASSWORD_GENERATED" == "1" ]]; then
      echo "root-Passwort (CT): ${ROOT_PASSWORD}"
    fi
    echo "Hostname: ${HOSTNAME_ARG}"
    echo "Log: ${LOG_FILE}"
  } >"$credentials_file"
  chmod 600 "$credentials_file"

  echo ""
  echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
  echo "  App          : ${APP_DISPLAY} ${APP_VERSION} (Rust/egui, Desktop via noVNC)"
  echo "  Container    : CT ${CTID} (Hostname: ${HOSTNAME_ARG}, unprivilegiert, onboot=1)"
  echo "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${SWAP} MB Swap / ${DISK} GB Disk"
  echo -e "  Web UI       : ${C_CYAN}http://${CT_IP}:${WEB_PORT}/vnc.html${C_RESET}"
  echo "  noVNC-Passwort: ${novnc_password}"
  echo "  Credentials  : ${credentials_file} (0600)"
  echo "  Log          : ${LOG_FILE}"
  echo ""
  echo "  Update       : bash ${APP}.sh --ctid ${CTID} --update"
  echo "  Neustart-Test: pct reboot ${CTID} && sleep 45 && pct exec ${CTID} -- systemctl is-active ${APP}-app"
  echo "  Uninstall    : bash ${APP}.sh --ctid ${CTID} --uninstall"
  echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
  echo ""
  echo "Sicherheitshinweis: noVNC laeuft ueber HTTP ohne TLS. Nur im LAN nutzen"
  echo "oder per SSH-Tunnel: ssh -L ${WEB_PORT}:localhost:${WEB_PORT} root@${CT_IP}"
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
do_uninstall() {
  if [[ -z "$CTID" ]]; then
    if ! CTID="$(find_existing_ct)"; then
      die "Kein Container mit Hostname '${HOSTNAME_ARG}' gefunden."
    fi
  fi
  pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID existiert nicht."
  local existing_host
  existing_host="$(pct config "$CTID" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')"
  if [[ "$existing_host" != "$HOSTNAME_ARG" && "$FORCE" != "1" ]]; then
    die "CT $CTID hat Hostname '${existing_host:-<leer>}', erwartet '${HOSTNAME_ARG}'. Abbruch. Nutze --hostname '${existing_host}' oder --force."
  fi
  if [[ "$ASSUME_YES" != "1" ]]; then
    if [[ -t 0 ]]; then
      local answer
      read -r -p "CT $CTID (${HOSTNAME_ARG}) wirklich stoppen und zerstoeren? [y/N] " answer
      [[ "$answer" =~ ^[yY]$ ]] || { msg_info "Abgebrochen."; exit 0; }
    else
      die "Bestaetigung erforderlich: --yes verwenden."
    fi
  fi
  msg_info "Stoppe CT $CTID ..."
  pct stop "$CTID" 2>/dev/null || true
  msg_info "Zerstoere CT $CTID ..."
  pct destroy "$CTID"
  rm -f "/root/bimcraft-${CTID}-credentials.txt"
  msg_ok "CT $CTID wurde entfernt."
  exit 0
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------
if [[ "$UNINSTALL" == "1" ]]; then
  do_uninstall
fi

resolve_ctid

if [[ "$UPDATE_ONLY" == "1" && "$REUSE" != "1" ]]; then
  die "--update verlangt einen vorhandenen Container (CT $CTID existiert nicht)."
fi

if [[ "$REUSE" != "1" ]]; then
  if [[ "$DEBUG" == "1" ]]; then set +x; fi
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(gen_password 16)"
    ROOT_PASSWORD_GENERATED="1"
  fi
  if [[ "$DEBUG" == "1" ]]; then set -x; fi
  resolve_storage
  ensure_template
fi

msg_info "Starte Container ..."
start_ct
wait_for_ip
ensure_dns
if resolve_mirror_ips; then
  msg_ok "Mirror-IPs aufgeloest: ${MIRROR_IPS% }"
else
  msg_warn "Konnte Mirror-IPs nicht aufloesen – fahre ohne /etc/hosts-Pinning fort."
  MIRROR_IPS=""
fi
install_ssh_key

provision_ct
verify_installation
print_summary
