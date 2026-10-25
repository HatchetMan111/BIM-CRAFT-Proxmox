# Test-Evidence – BIMCraft Proxmox Installer

Stand: 2026-10-24

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

## 1. Statische Checks

```bash
bash -n install/bimcraft.sh
bash -n tests/reboot-test.sh
shellcheck -S warning install/bimcraft.sh tests/reboot-test.sh
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

Fuer den echten Nachweis auf Proxmox:

```bash
bash install/bimcraft.sh --ctid 150
./tests/reboot-test.sh 150 --reboot
```
