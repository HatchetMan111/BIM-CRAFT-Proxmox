#!/usr/bin/env bash
#
# BIMCraft Proxmox – DNS-/apt-Resilienztest (Docker)
#
# Reproduziert den Real-Host-Fehlerfall:
#   - /etc/hosts ist fuer den apt-Benutzer _apt nicht lesbar (0600)
#   - DNS im Container ist komplett blockiert (Port 53 verworfen)
# und prueft, dass die Provisionierung trotzdem durchlaeuft, weil der
# Installer die Mirror-Hosts als IPv4 pinnt und /etc/hosts lesbar macht.
#
# Usage:
#   sudo ./tests/dns-resilience-test.sh [--keep]
#
# Voraussetzungen: root, docker, Netzwerk auf dem Host (zum Aufloesen der
# Mirror-IPs VOR dem Blockieren), ca. 3-5 Minuten Laufzeit.
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install/bimcraft.sh"
IMAGE="${BIMCRAFT_TEST_IMAGE:-bimcraft-test:12}"
CTR="bimcraft-dns-resilience"
KEEP=0
LOG="${TMPDIR:-/tmp}/bimcraft-dns-resilience.log"

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_BLUE=""
fi
info() { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()   { echo -e "${C_GREEN}[PASS]${C_RESET}  $*"; PASS=$((PASS + 1)); }
bad()  { echo -e "${C_RED}[FAIL]${C_RESET}  $*"; FAIL=$((FAIL + 1)); }
die()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 2; }

[[ "$(id -u)" -eq 0 ]] || die "Bitte als root ausfuehren (docker/systemd-Container)."
command -v docker >/dev/null 2>&1 || die "docker nicht gefunden."
[[ -f "$INSTALLER" ]] || die "Installer nicht gefunden: $INSTALLER"

cleanup() {
  if (( KEEP == 0 )); then
    docker rm -f "$CTR" >/dev/null 2>&1 || true
  else
    info "Container '$CTR' bleibt erhalten; Log: $LOG"
  fi
}
trap cleanup EXIT

# Provision-Script aus dem Installer extrahieren (zwischen den Markern).
PROV="$(mktemp)"
trap 'rm -f "$PROV"; cleanup' EXIT
awk '
  /<<.PROVISION_SCRIPT.$/ { inside = 1; next }
  inside && /^PROVISION_SCRIPT$/ { exit }
  inside { print }
' "$INSTALLER" > "$PROV"
[[ -s "$PROV" ]] || die "Provision-Script konnte nicht extrahiert werden."
bash -n "$PROV" || die "Extrahiertes Provision-Script ist syntaktisch fehlerhaft."

info "Baue Testimage ${IMAGE} (nur beim ersten Lauf) ..."
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  build_dir="$(mktemp -d)"
  cat > "$build_dir/Dockerfile" <<'EOF'
FROM debian:12
RUN apt-get update && apt-get install -y --no-install-recommends systemd iptables ca-certificates && apt-get clean
CMD ["/lib/systemd/systemd"]
EOF
  docker build -q -t "$IMAGE" "$build_dir" >/dev/null || die "Image-Build fehlgeschlagen."
  rm -rf "$build_dir"
fi

# Mirror-IPs VOR dem DNS-Block auf dem Host aufloesen (wie der Host-Pfad).
MIRROR_IPS=""
for host in deb.debian.org security.debian.org github.com \
            objects.githubusercontent.com release-assets.githubusercontent.com; do
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$ip" ]] || die "Host kann ${host} nicht aufloesen (Test braucht Host-DNS)."
  MIRROR_IPS+="${host}=${ip} "
done
info "Mirror-IPs: ${MIRROR_IPS% }"

docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$CTR" systemctl is-system-running >/dev/null 2>&1 && break
  sleep 1
done
docker cp "$PROV" "$CTR:/root/bimcraft-provision.sh"

# Fehlerfall herstellen: Hosts 0600, DNS tot.
docker exec "$CTR" sh -c '
  printf "options timeout:1 attempts:1\nnameserver 127.0.0.53\n" > /etc/resolv.conf
  iptables -A OUTPUT -p udp --dport 53 -j DROP
  iptables -A OUTPUT -p tcp --dport 53 -j DROP
  chmod 0600 /etc/hosts
' || die "Fehlerfall konnte nicht hergestellt werden."

# Ursache belegen: _apt kann /etc/hosts nicht lesen.
if docker exec "$CTR" runuser -u _apt -- getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
  bad "_apt konnte /etc/hosts trotz 0600 lesen (Testfall ungueltig)."
else
  ok "_apt kann /etc/hosts bei 0600 nicht lesen (Ursache reproduziert)."
fi

info "Starte Provisionierung mit blockiertem DNS ..."
rc=0
docker exec \
  -e BIMCRAFT_VERSION="${BIMCRAFT_VERSION:-0.7.0}" \
  -e BIMCRAFT_NOVNC_PASSWORD=test-passwort \
  -e BIMCRAFT_DNS="${BIMCRAFT_DNS:-192.168.178.111}" \
  -e "BIMCRAFT_MIRROR_IPS=$MIRROR_IPS" \
  -e BIMCRAFT_DEBUG=0 \
  "$CTR" bash /root/bimcraft-provision.sh > "$LOG" 2>&1 || rc=$?

if (( rc == 0 )); then
  ok "Provisionierung Exit 0 bei blockiertem DNS."
else
  bad "Provisionierung Exit ${rc} (Log: $LOG)."
fi

grep -q "Provisionierung abgeschlossen" "$LOG" \
  && ok "Provisionierung abgeschlossen." \
  || bad "Abschlussmeldung fehlt."

grep -q "Mirror-Pins aktiv" "$LOG" \
  && ok "Mirror-Pins wurden als gueltig erkannt." \
  || bad "Mirror-Pins wurden nicht als gueltig erkannt."

if grep -q "Temporary failure resolving" "$LOG"; then
  bad "apt meldet weiterhin 'Temporary failure resolving'."
else
  ok "Keine 'Temporary failure resolving'-Fehler im Log."
fi

perms="$(docker exec "$CTR" stat -c '%a' /etc/hosts 2>/dev/null || echo '?')"
[[ "$perms" == "644" ]] \
  && ok "/etc/hosts ist 0644." \
  || bad "/etc/hosts ist ${perms}, erwartet 0644."

pins="$(docker exec "$CTR" grep -c '# bimcraft-mirror-pin' /etc/hosts 2>/dev/null || echo 0)"
(( pins >= 2 )) \
  && ok "${pins} Mirror-Pins in /etc/hosts." \
  || bad "Zu wenige Mirror-Pins (${pins})."

nss="$(docker exec "$CTR" awk '/^hosts:/ {print $0}' /etc/nsswitch.conf 2>/dev/null || true)"
case "$nss" in
  *files*dns*) ok "nsswitch.conf unveraendert (${nss//[[:space:]]/ })." ;;
  *) bad "nsswitch.conf wurde veraendert: '${nss}'." ;;
esac

echo ""
if (( FAIL == 0 )); then
  echo -e "${C_GREEN}Alle ${PASS} Checks bestanden.${C_RESET}"
  exit 0
fi
echo -e "${C_RED}${FAIL} Check(s) fehlgeschlagen, ${PASS} bestanden. Log: $LOG${C_RESET}"
exit 1
