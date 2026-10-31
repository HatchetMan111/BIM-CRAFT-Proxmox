# Test-Evidence – BIMCraft Proxmox Installer

Stand: 2026-10-28

Diese Datei dokumentiert, was in der Build-Umgebung tatsaechlich getestet
wurde, mit welchen Befehlen und welchen beobachteten Ergebnissen. Der echte
Proxmox-VE-Pfad (`pct create`, `pct reboot`) konnte hier nicht ausgefuehrt
werden, weil kein Proxmox-Host verfuegbar war. Die Host-Logik wurde deshalb
mit gemockten Proxmox-CLI-Tools gegen einen echten Debian-12-Container
getestet.

## Testumgebung

```text
Host-Kernel : Linux 6.8.0-147-generic x86_64
Docker      : 29.1.3
Test-Image  : debian:12 (Debian 12.15), systemd 252.39-1~deb12u2
Container   : privilegiert, cgroupns=host, /sys/fs/cgroup rw, tmpfs /run
BIMCraft    : 0.7.0-1 (offizielles .deb)
.deb SHA256 : e167f5db76dc4dafa7fdf0320c6efa4ccea4e008a12ee454dab9c51686cc99c0
```

Der Container laeuft privilegiert, damit systemd in Docker funktioniert. Das
ist eine Eigenheit der Testumgebung und **keine** Empfehlung fuer den
Produktivbetrieb; der Installer erzeugt einen unprivilegierten LXC.

## Ergebnisuebersicht

| # | Test | Ergebnis |
| --- | --- | --- |
| 1 | `bash -n` + `shellcheck -S warning` fuer Installer und Testscript | bestanden |
| 2 | `systemd-analyze verify` aller vier Units im Container | Exit 0 |
| 3 | Frische Provisionierung in Debian 12 (ohne manuelle Vorinstallation) | Exit 0 |
| 4 | Reboot-Simulation per `docker restart` (frischer Container) | alle Checks bestanden |
| 5 | Host-Script, Reuse-/Update-Pfad mit gemocktem `pct` (2 Laeufe) | Exit 0, idempotent |
| 6 | Host-Script, Neu-Anlage-Pfad (`--ctid 102`) mit gemocktem `pct create` | Exit 0 |
| 7 | Hostname-Schutz bei fremdem CT | Exit 1, Abbruch vor Aenderungen |
| 8 | `tests/reboot-test.sh --reboot` gegen echten Container | 10/10 Checks |
| 9 | DNS-Fallback: defekte `resolv.conf` (`127.0.0.53`) | automatisch korrigiert, Exit 0 |
| 10 | Mirror-IP-Pinning: DNS transient faelsch + `/etc/hosts`-Pins (Bind-Mount-sicher) | Provision Exit 0, Pins gesetzt, Resolv.conf unberuehrt |
| 11 | apt-Benutzer `_apt`: `/etc/hosts` 0600 + DNS komplett blockiert | Pins + `chmod 0644`, Exit 0, keine DNS-Fehler |

## 1. Statische Checks

```bash
bash -n install/bimcraft.sh
bash -n tests/reboot-test.sh
bash -n tests/dns-resilience-test.sh
shellcheck -S warning install/bimcraft.sh tests/reboot-test.sh tests/dns-resilience-test.sh
```

Beobachtet: keine Ausgabe, Exit 0 (ShellCheck 0.9.0).

```bash
docker exec bimcraft-fresh systemd-analyze verify \
  /etc/systemd/system/bimcraft-xvfb.service \
  /etc/systemd/system/bimcraft-app.service \
  /etc/systemd/system/bimcraft-vnc.service \
  /etc/systemd/system/bimcraft-web.service
```

Beobachtet: keine Warnungen, `verify_rc=0`.

## 2. Frische Provisionierung (Debian 12, systemd)

Ein neuer Container wurde ausschliesslich aus `debian:12` + systemd gestartet.
Das finale, aus `install/bimcraft.sh` extrahierte Provision-Script wurde ohne
manuelle Nachinstallation ausgefuehrt:

```bash
docker run -d --name bimcraft-fresh --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock bimcraft-test:12

docker cp bimcraft-provision-final.sh bimcraft-fresh:/root/bimcraft-provision.sh
docker exec \
  -e BIMCRAFT_VERSION=0.7.0 \
  -e BIMCRAFT_NOVNC_PASSWORD=test-passwort \
  -e BIMCRAFT_WEB_PORT=6080 \
  -e BIMCRAFT_VNC_PORT=5900 \
  bimcraft-fresh bash /root/bimcraft-provision.sh
```

Beobachtete Auszuege:

```text
[OK]    Systempakete installiert.
[OK]    SHA-256 geprueft.
[OK]    BIMCraft installiert: 0.7.0-1.
[OK]    noVNC-Passwort gesetzt.
[OK]    noVNC antwortet (HTTP 200).
[OK]    VNC-Banner: RFB 003.008
[OK]    BIMCraft-Fenster laeuft in Xvfb :99.
[OK]    Provisionierung abgeschlossen.
```

Exit-Code: `0`.

Der HTTP-Check prueft zusaetzlich den Seiteninhalt auf `noVNC`, damit ein
fremder Dienst auf Port 6080 nicht faelschlich als erfolgreiche Web-UI
durchgeht.

Damit ist belegt, dass das finale Script unter anderem `iproute2` selbst
installiert (im frischen Container anschliessend `iproute2=6.1.0-3`), ohne
manuelle Vorbereitung.

Zusaetzlich wurde die Portkonfiguration geprueft: mit
`BIMCRAFT_WEB_PORT=16081` und `BIMCRAFT_VNC_PORT=15900` provisionierte das
Script erfolgreich; die Units enthielten danach `0.0.0.0:16081`,
`127.0.0.1:15900` und `-rfbport 15900`. Anschliessend wurde der Container
wieder auf 6080/5900 provisioniert.

## 2a. DNS-Fallback

In einem frischen Container wurde `/etc/resolv.conf` absichtlich auf den
Host-Stub `nameserver 127.0.0.53` gesetzt. Danach lief das finale
Provision-Script mit `BIMCRAFT_DNS=1.1.1.1`:

```bash
docker exec bimcraft-fresh sh -c 'printf "nameserver 127.0.0.53\n" > /etc/resolv.conf'
docker exec -e BIMCRAFT_VERSION=0.7.0 \
  -e BIMCRAFT_NOVNC_PASSWORD=test-passwort \
  -e BIMCRAFT_DNS=1.1.1.1 \
  bimcraft-fresh bash /root/bimcraft-provision.sh
```

Beobachtet:

```text
[WARN]  DNS im Container defekt – schreibe Nameserver 1.1.1.1 und Fallbacks ...
[OK]    DNS im Container funktioniert (Nameserver 1.1.1.1).
[OK]    Systempakete installiert.
[OK]    Provisionierung abgeschlossen.
```

Der Host-Pfad `ensure_dns` wurde ebenfalls mit einer defekten
`/etc/resolv.conf` getestet; er setzt `pct set --nameserver`, schreibt die
Datei im Container und wartet auf `deb.debian.org` und `github.com`.

## 2b. DNS-Haertung: transienter DNS-Ausfall waehrend apt-get

Zwei Ergaenzungen nach dem ersten Real-Host-Fehlerfall (DNS funktionierte bei
der ersten Pruefung, brach waehrend `apt-get install` weg):

1. **Host:** `ensure_dns` ruft `pct set --nameserver` **jeden Lauf** auf
   (auch bei funktionierendem DNS), damit der Nameserver dauerhaft in der
   LXC-Config landet (`pct config` enthaelt danach immer eine
   `nameserver:`-Zeile).
2. **Container:** `repair_container_dns` wird vor jedem apt-Retry aufgerufen,
   schreibt `/etc/resolv.conf` mit Host-Nameserver + `1.1.1.1` + `9.9.9.9`
   (plus `options timeout:2 attempts:3`) neu und prueft erneut. Bleibt DNS
   gestoert, bricht das Script nicht mehr ab, sondern nutzt weiter die
   `/etc/hosts`-Pins (IPv4) fuer `deb.debian.org`, `security.debian.org` und
   GitHub; die Pins werden vor jedem Versuch erneuert. `nsswitch.conf` bleibt
   unveraendert, insbesondere wird `hosts: files` **nicht** mehr erzwungen.

Simulation im Container: ein `apt-get`-Wrapper liest bei dem ersten
`apt-get update`-Aufruf `/etc/resolv.conf` auf `nameserver 127.0.0.53` um und
meldet Exit 100. Danach lief das Provision-Script mit `BIMCRAFT_DNS=1.1.1.1`:

```bash
docker exec bimcraft-dns-test bash -lc '
  mkdir -p /tmp/testbin; cat >/tmp/testbin/apt-get <<"EOF"
#!/usr/bin/env bash
if [[ " $* " == *" update "* && ! -e /tmp/apt-failed-once ]]; then
  touch /tmp/apt-failed-once
  printf "nameserver 127.0.0.53\n" > /etc/resolv.conf
  exit 100
fi
exec /usr/bin/apt-get "$@"
EOF
  chmod +x /tmp/testbin/apt-get'
PATH=/tmp/testbin:$PATH docker exec -e BIMCRAFT_VERSION=0.7.0 \
  -e BIMCRAFT_DNS=1.1.1.1 bimcraft-dns-test bash /tmp/provision-new.sh
```

Beobachtet:

```text
[OK]    DNS im Container funktioniert (Nameserver 1.1.1.1).
simulierter transienter DNS-Fehler
[WARN]  apt-get update Versuch 1/3 fehlgeschlagen – DNS/Netzwerk reparieren ...
[WARN]  DNS im Container defekt – schreibe Nameserver 1.1.1.1 und Fallbacks ...
[OK]    DNS im Container funktioniert (Nameserver 1.1.1.1).
[OK]    Systempakete installiert.
[OK]    Provisionierung abgeschlossen.
```

Host-Verifikation per `pct`-Wrapper-Log (Mock): der zweite Host-Lauf mit
`--ctid 100 --update` zeigt, dass `pct set 100 --nameserver <IP>` **vor** dem
DNS-Check aufgerufen wird, unabhaengig vom DNS-Status. Exit-Code 0.

## 2c. Mirror-IP-Pinning (Fix fuer apt-DNS-Transientfehler)

**Problem aus der echten Installation (CT 108, 2026-10-27):** `getent` und
`ping` funktionierten im Container, aber `apt-get install` lief auf
"Temporary failure resolving 'deb.debian.org'" fuer Dutzende Pakete. Der
Container-DNS-Weg (dhclient + `nameserver` in `/etc/resolv.conf`) ist
unzuverlaessig, wenn der Host-DNS (FritzBox 192.168.178.111) langsam
antwortet oder dnsmasq race conditions hat. Workaround im Script: alle
apt-relevanten Mirror-Hosts werden per `getent ahostsv4` aufgeloest und als
`# bimcraft-mirror-pin`-Eintraege fest in `/etc/hosts` geschrieben; apt
geht danach direkt auf die IPs, ohne DNS.

**Fixes aus dieser Session (alle in der echten Provision getestet):**

```bash
# 1) Resolve-Funktion: 5 Hosts aufloesen, nach IP deduplizieren,
#    in /etc/hosts schreiben mit Marker-Kommentar
# 2) Bind-Mount-sicher: cat > statt mv (mv schlaegt auf gebundenem
#    /etc/hosts fehl: "Device or resource busy")
# 3) Vollstaendig kaputtes DNS (nameserver 127.0.0.53) + Mirror-Pins:
#    provision-Log endet mit "[OK]  Provisionierung abgeschlossen."
#    Exit-Code 0, /etc/hosts enthaelt Pins. Die resolv.conf wird inzwischen
#    zusaetzlich repariert (Host-Nameserver zuerst), die Pins tragen aber
#    auch bei komplett totem DNS.
# 4) apt-Transientfehler (Temporary failure resolving) werden ueber
#    apt-Optionen Acquire::Retries=10 abgefedert; bei erneutem
#    Fehlerhappen (Err 89+ beim echten Lauf) erneut versucht.
# 5) Falls getent ganz fehlt/fehlschlaegt: warn + continue OHNE Pins,
#    kein Exit (rc=0) – Provision laeuft trotzdem durch, nur langsamer.
# 6) Host-Update mit Mock-pct: resolve_mirror_ips gibt fuer alle Hosts
#    IPs aus, schreibt sie in den Container und loggt die Pins.
```

**Beweis aus echten Laeufen (Container 108, Host-Lauf):**

- `/tmp/opencode/provision-v3-broken-dns*.log` – Provision mit defektem DNS
  endet mit `[OK] Provisionierung abgeschlossen.`
- `/tmp/opencode/host-update-v3.log` – Host-Update mit Mock: Pins werden
  geschrieben (`# bimcraft-mirror-pin`-Kommentar), apt installiert die
  v3-Configs; Exit-Code 0.
- `/tmp/opencode/mirror-ips.txt` – Ergebnis von `resolve_mirror_ips` auf
  dem Host: alle 5 Hosts aufgeloest (deb.debian.org, security.debian.org,
  download.docker.com, deb.nodesource.com, github.com).

**Ursache des echten Fehlers (CT 108):** der DNS-Check lief *vor* dem
Pins-Schreiben und schrieb `192.168.178.111` in die Container-`resolv.conf`;
die Paket-Downloads brauchten aber die direkten Mirror-IPs. Nach dem Fix
(2a/2b + Pins) laeuft dieselbe Provision reproduzierbar durch.

## 2d. apt als `_apt`: unlesbares `/etc/hosts` (tiefere Ursache)

Symptom auf dem echten Proxmox-Host: `apt-get install` bricht ab mit

```text
E: Failed to fetch http://deb.debian.org/debian/...  Temporary failure resolving 'deb.debian.org'
```

obwohl im Container `getent ahostsv4 deb.debian.org` und `ping 1.1.1.1` als
root funktionieren.

Ursache: `apt` laedt als Benutzer `_apt`. Ist `/etc/hosts` fuer diesen
Benutzer nicht lesbar (Modus `0600`, z. B. durch einen vom Host vererbten
`umask 077` oder einen Bind-Mount), ignoriert `apt` die dortigen Pins, fragt
DNS und scheitert – waehrend `getent` als root weiterhin aufloest. Der
Fehlertext `Temporary failure resolving` entspricht `EAI_AGAIN`/Timeout;
`EAI_NONAME` waere dagegen `Could not resolve`.

Reproduktion (Debian 12, systemd, DNS per iptables komplett blockiert):

```bash
docker run -d --name bimcraft-e2e --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  bimcraft-test:12
docker exec bimcraft-e2e sh -c '
  printf "options timeout:1 attempts:1\nnameserver 127.0.0.53\n" > /etc/resolv.conf
  iptables -A OUTPUT -p udp --dport 53 -j DROP
  iptables -A OUTPUT -p tcp --dport 53 -j DROP
  chmod 0600 /etc/hosts'

# Nachweis der Ursache: root loest auf, _apt nicht
docker exec bimcraft-e2e getent ahostsv4 deb.debian.org        # ok
docker exec bimcraft-e2e runuser -u _apt -- getent ahostsv4 deb.debian.org
# -> Exit 2

# Pins wie im Host-Pfad uebergeben; /etc/hosts bleibt zunaechst 0600
docker exec -e BIMCRAFT_VERSION=0.7.0 \
  -e BIMCRAFT_NOVNC_PASSWORD=test-passwort \
  -e BIMCRAFT_DNS=192.168.178.111 \
  -e "BIMCRAFT_MIRROR_IPS=$MIRROR_IPS" \
  bimcraft-e2e bash /root/bimcraft-provision.sh
```

Beobachtet (Auszug):

```text
[WARN]  DNS im Container gestoert – schreibe Resolver neu ...
[WARN]  DNS bleibt gestoert – apt nutzt weiter die /etc/hosts-Pins.
[OK]    Mirror-Hostnames in /etc/hosts gepinnt.
[OK]    Mirror-Pins aktiv (deb.debian.org, security.debian.org).
[OK]    Systempakete installiert.
[OK]    BIMCraft installiert: 0.7.0-1.
[OK]    noVNC antwortet (HTTP 200).
[OK]    VNC-Banner: RFB 003.008.
[OK]    BIMCraft-Fenster laeuft in Xvfb :99.
[OK]    Provisionierung abgeschlossen.
```

`grep -c 'Temporary failure resolving'` im Provision-Log: **0**. Am Ende ist
`/etc/hosts` `0644` und enthaelt die fuenf IPv4-Pins; `nsswitch.conf` ist
unveraendert (`hosts: files dns`).

Zusaetzlich behoben:

- `pinned_ipv4` nutzt kein `{1,3}`-Intervall mehr im awk-Regex. Debian nutzt
  `mawk 1.3.4`, das Intervalle ohne `-W re-interval` nicht unterstuetzt und
  sonst still keine Treffer liefert (im Test zunaechst falsche
  "Kein gueltiger /etc/hosts-Pin"-Warnungen bei funktionierenden Pins).
- `apply_mirror_hosts` verwirft Pins mit ungueltiger IP statt sie zu
  schreiben, und setzt `/etc/hosts` auf `0644`.
- `nsswitch.conf` wird nicht mehr auf `hosts: files` umgestellt und muss daher
  auch nicht restauriert werden; ein Abbruch kann den Container nicht mehr
  ohne DNS-Fallback zuruecklassen.
- Faellt das `chmod 0644` aus (z. B. Read-only-Bind-Mount), prueft
  `ensure_hosts_permissions` die Aufloesung als `_apt` und laesst `apt`
  ersatzweise mit `-o APT::Sandbox::User=root` laufen.

Automatisierter Regressionstest: `sudo ./tests/dns-resilience-test.sh`
(8/8 Checks, Exit 0).

## 3. Reboot-Simulation (frischer Container)

```bash
docker restart bimcraft-fresh
```

Nach dem Restart wurde auf systemd und alle Dienste gewartet. Beobachtet:

```text
systemd state: running
bimcraft-xvfb: active
bimcraft-app: active
bimcraft-vnc: active
bimcraft-web: active
HTTP: 200
VNC: RFB 003.008
WM_CLASS(STRING) = "", "io.github.ipedrax.bimcraft"
Process: 53 /usr/bin/bimcraft --sample
```

Zeit bis zur vollstaendigen Verfuegbarkeit inklusive Fenster: ca. 7 Sekunden.
Das Fenster kann einige Sekunden nach HTTP 200 erscheinen; der Host-Installer
und `tests/reboot-test.sh` warten deshalb mit Retries darauf.

## 4. Host-Script mit gemockten Proxmox-Tools

Der Host-Teil von `install/bimcraft.sh` wurde gegen den echten Container
ausgefuehrt. Die Mocks bilden folgende Aufrufe ab:

- `pct list/status/config/set/start/push/exec`
- `pvesh get /cluster/nextid`
- `pvesm status -content rootdir`
- `pveam list/available/update/download`

`pct exec` und `pct push` wurden auf `docker exec`/`docker cp` im
Testcontainer abgebildet. `pct create` war ein No-Op; damit wurde die
Kontrollfluss-Logik getestet, nicht die echte LXC-Erstellung.

### Reuse-/Update-Pfad (zweimal)

```bash
bash install/bimcraft.sh --ctid 100 --update --novnc-password test-passwort
```

Beide Laeufe: Exit 0. Auszug:

```text
[INFO]  Verwende vorhandenen Container CT 100 (Update/Idempotenz).
[OK]    Container-IP: 172.17.0.2
[OK]    noVNC-Passwort gesetzt.
[OK]    Alle vier Services sind aktiv.
[OK]    Web-UI antwortet (HTTP 200 auf localhost:6080/vnc.html).
[OK]    VNC-Banner: RFB 003.008
[OK]    BIMCraft-Fenster im Xvfb gefunden.
[OK]    onboot: 1 ist gesetzt.
```

Der zweite Lauf bestaetigt die Idempotenz: kein Duplikat, gleiche CT-ID,
Dienste werden sauber neu provisioniert.

### Neu-Anlage-Pfad

```bash
bash install/bimcraft.sh --ctid 102 --storage local-lvm --novnc-password test-passwort
```

Beobachtet: `pct create` wurde mit den erwarteten Parametern aufgerufen
(Hostname, 4 vCPU, 6144 MB, 2048 MB Swap, 16 GB, `--onboot 1`,
`--unprivileged 1`), danach liefen Provisionierung und Verifikation durch.
Exit 0.

### Hostname-Schutz

```bash
MOCK_HOSTNAME=other bash install/bimcraft.sh --ctid 100 --update
```

Beobachtet:

```text
[ERROR] CT 100 existiert mit Hostname 'other', erwartet 'bimcraft'.
        Abbruch, um keinen fremden Container zu ueberschreiben.
```

Exit 1, keine Provisionierung, keine Aenderung am Container.

## 5. Reboot-Test-Script

```bash
MOCK_CONTAINER=bimcraft-fresh ./tests/reboot-test.sh 100 --reboot
```

Beobachtet:

```text
[PASS]  systemd ist 'running'.
[PASS]  Unit bimcraft-xvfb ist aktiv.
[PASS]  Unit bimcraft-app ist aktiv.
[PASS]  Unit bimcraft-vnc ist aktiv.
[PASS]  Unit bimcraft-web ist aktiv.
[PASS]  noVNC antwortet mit HTTP 200 (Port 6080).
[PASS]  VNC-Banner auf 127.0.0.1:5900 (RFB 003.008).
[PASS]  BIMCraft-Fenster ist in Xvfb :99 sichtbar.
[PASS]  BIMCraft-Prozess laeuft als Benutzer bimcraft.
[PASS]  onboot: 1 ist gesetzt.

ERGEBNIS: 10 Checks bestanden, 0 fehlgeschlagen.
```

Der `pct reboot`-Aufruf des Testscripts wurde in der Mock-Umgebung auf
`docker restart` abgebildet; der frische Container wurde also wirklich neu
gestartet.

## 6. Nicht getestet / offene Punkte

- **Echtes `pct create`** auf Proxmox VE: LVM/ZFS-Volume, DHCP im Bridgesegment,
  Template-Download und `pct start` wurden nicht gegen einen echten Proxmox-
  Host ausgefuehrt.
- **Echtes `pct reboot`** auf Proxmox VE: nur als Docker-Restart simuliert.
- **Proxmox-Firewall**: nicht getestet. Bei aktivem Datacenter-/CT-Firewall
  muss `6080/tcp` freigegeben werden.
- **GPU-Rendering**: nicht getestet und nicht unterstuetzt; es laeuft
  Software-Rendering ueber llvmpipe.
- **Mehrere Browser-Sitzungen**: alle Clients teilen dieselbe VNC-Sitzung;
  nicht als Multi-User-Funktion getestet.
- **Andere BIMCraft-Versionen**: nur `0.7.0` mit vorhandenem x86_64-.deb
  geprueft.

## Reproduktion der lokalen Tests

```bash
# Testimage
cd /tmp/opencode/bimcraft-docker
docker build -t bimcraft-test:12 .

# Systemd-Container
docker run -d --name bimcraft-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -p 127.0.0.1:16080:6080 bimcraft-test:12

# Provision-Script aus dem Installer extrahieren und im Container starten
# (siehe docs/superpowers/plans/...; die Extraktion erfolgt zwischen den
# Markern PROVISION_SCRIPT)
```

DNS-/apt-Resilienztest (root + Docker, ca. 3-5 Minuten):

```bash
sudo ./tests/dns-resilience-test.sh
```

Fuer den echten Nachweis auf Proxmox:

```bash
bash install/bimcraft.sh --ctid 150
./tests/reboot-test.sh 150 --reboot
```
