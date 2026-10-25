#!/usr/bin/env bash
#
# BIMCraft Proxmox – Reboot-/Health-Test
#
# Prueft nach einem Neustart des LXC, ob alle Dienste, die Web-UI, VNC und
# das BIMCraft-Fenster wieder da sind. Optional wird der Container vorher
# per "pct reboot" neu gestartet.
#
# Usage:
#   ./tests/reboot-test.sh [CTID] [--reboot] [--wait SEKUNDEN]
#
# Ohne CTID wird der Container mit Hostname "bimcraft" gesucht.
#
set -Eeuo pipefail

APP="bimcraft"
WEB_PORT="${BIMCRAFT_WEB_PORT:-${WEB_PORT:-6080}}"
VNC_PORT="${BIMCRAFT_VNC_PORT:-${VNC_PORT:-5900}}"
WAIT="${WAIT:-90}"
DO_REBOOT="0"
CTID=""

PASS=0
FAIL=0

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_BLUE=$'\e[34m' C_YELLOW=$'\e[33m'
else
  C_RESET="" C_RED="" C_GREEN="" C_BLUE="" C_YELLOW=""
fi

info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()    { echo -e "${C_GREEN}[PASS]${C_RESET}  $*"; PASS=$((PASS + 1)); }
bad()   { echo -e "${C_RED}[FAIL]${C_RESET}  $*"; FAIL=$((FAIL + 1)); }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
die()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 2; }

usage() {
  cat <<EOF
BIMCraft Proxmox Reboot-Test

Usage:
  ./tests/reboot-test.sh [CTID] [--reboot] [--wait SEKUNDEN]

Optionen:
  --reboot        Container vor dem Test mit 'pct reboot' neu starten
  --wait N        Maximale Wartezeit auf den Boot (Default: ${WAIT} s)
  -h, --help      diese Hilfe

Ohne CTID wird der Container mit Hostname '${APP}' gesucht.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)       DO_REBOOT="1"; shift ;;
    --wait)         WAIT="${2:?--wait braucht einen Wert}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "Unbekannte Option: $1 (siehe --help)" ;;
    *)
      [[ -z "$CTID" ]] || die "Es wird nur eine CTID unterstuetzt."
      CTID="$1"; shift ;;
  esac
done

[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren (sudo -i)."
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – laeuft das Script auf einem Proxmox-VE-Host?"
[[ "$WAIT" =~ ^[0-9]+$ ]] || die "--wait muss eine Zahl sein."

find_ct() {
  local id host
  while read -r id; do
    [[ -n "$id" ]] || continue
    host="$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')"
    if [[ "$host" == "$APP" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(pct list | awk 'NR>1 {print $1}')
  return 1
}

if [[ -z "$CTID" ]]; then
  CTID="$(find_ct)" || die "Kein Container mit Hostname '${APP}' gefunden. CTID explizit angeben."
fi

pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID existiert nicht."

info "Teste CT $CTID (Hostname: ${APP})"

if [[ "$DO_REBOOT" == "1" ]]; then
  info "Starte CT $CTID neu (pct reboot) ..."
  pct reboot "$CTID"
  sleep 3
fi

info "Warte auf systemd (max. ${WAIT}s) ..."
state=""
for _ in $(seq 1 "$WAIT"); do
  state="$(pct exec "$CTID" -- systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "degraded" ]]; then
    break
  fi
  sleep 1
done
if [[ "$state" == "running" || "$state" == "degraded" ]]; then
  ok "systemd ist '${state}'."
  [[ "$state" == "degraded" ]] && warn "systemd meldet 'degraded' – Details: systemctl --failed"
else
  bad "systemd wurde nicht rechtzeitig bereit (Status: '${state:-unbekannt}')."
fi

for unit in "${APP}-xvfb" "${APP}-app" "${APP}-vnc" "${APP}-web"; do
  if pct exec "$CTID" -- systemctl is-active --quiet "$unit"; then
    ok "Unit ${unit} ist aktiv."
  else
    bad "Unit ${unit} ist nicht aktiv."
  fi
done

http_code=""
for _ in $(seq 1 60); do
  http_code="$(pct exec "$CTID" -- curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${WEB_PORT}/vnc.html" 2>/dev/null || true)"
  [[ "$http_code" == "200" ]] && break
  sleep 1
done
if [[ "$http_code" == "200" ]]; then
  ok "noVNC antwortet mit HTTP 200 (Port ${WEB_PORT})."
else
  bad "noVNC antwortet nicht mit HTTP 200 (erhalten: '${http_code:-keine Antwort}')."
fi

banner=""
for _ in $(seq 1 30); do
  banner="$(timeout 5 pct exec "$CTID" -- bash -c \
    "exec 3<>/dev/tcp/127.0.0.1/${VNC_PORT}; head -c 12 <&3" 2>/dev/null || true)"
  [[ "$banner" == RFB* ]] && break
  sleep 1
done
if [[ "$banner" == RFB* ]]; then
  ok "VNC-Banner auf 127.0.0.1:${VNC_PORT} (${banner})."
else
  bad "Kein VNC-Banner auf 127.0.0.1:${VNC_PORT} (erhalten: '${banner:-leer}')."
fi

window_ok="0"
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- bash -c \
    'for id in $(DISPLAY=:99 xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o "0x[0-9a-fA-F]*"); do DISPLAY=:99 xprop -id "$id" WM_CLASS 2>/dev/null | grep -qi bimcraft && exit 0; done; exit 1'; then
    window_ok="1"
    break
  fi
  sleep 2
done
if [[ "$window_ok" == "1" ]]; then
  ok "BIMCraft-Fenster ist in Xvfb :99 sichtbar."
else
  bad "Kein BIMCraft-Fenster in Xvfb :99 gefunden."
fi

if pct exec "$CTID" -- pgrep -u "$APP" -x "$APP" >/dev/null 2>&1; then
  ok "BIMCraft-Prozess laeuft als Benutzer ${APP}."
else
  bad "BIMCraft-Prozess laeuft nicht."
fi

ct_config="$(pct config "$CTID" 2>/dev/null || true)"
if grep -q '^onboot: 1$' <<<"$ct_config"; then
  ok "onboot: 1 ist gesetzt."
else
  bad "onboot: 1 ist nicht gesetzt."
fi

echo ""
if (( FAIL == 0 )); then
  echo -e "${C_GREEN}ERGEBNIS: ${PASS} Checks bestanden, 0 fehlgeschlagen.${C_RESET}"
  exit 0
fi

echo -e "${C_RED}ERGEBNIS: ${PASS} bestanden, ${FAIL} fehlgeschlagen.${C_RESET}"
echo ""
echo "--- Diagnose ---"
for unit in "${APP}-xvfb" "${APP}-app" "${APP}-vnc" "${APP}-web"; do
  echo ""
  echo "### systemctl status ${unit}"
  pct exec "$CTID" -- systemctl status "$unit" --no-pager -l 2>&1 || true
  echo ""
  echo "### journalctl -u ${unit} (letzte 60 Zeilen)"
  pct exec "$CTID" -- journalctl -u "$unit" --no-pager -n 60 2>&1 || true
done
echo ""
echo "### Provision-Log (letzte 60 Zeilen)"
pct exec "$CTID" -- tail -n 60 /var/log/bimcraft-provision.log 2>&1 || true
exit 1
