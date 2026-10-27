# BIMCraft auf Proxmox VE (LXC + noVNC)

Installiert [BIMCraft](https://github.com/IPedrax/BIMCraft) als schlanken
Debian-12-LXC auf Proxmox VE und stellt das native Desktop-Fenster per
**Xvfb + x11vnc + noVNC** im Browser bereit.

BIMCraft ist eine Desktop-Anwendung (Rust/egui) und bringt **keine Web-UI**
mit. Dieses Projekt verpackt die offizielle Linux-.deb in einen LXC, startet
die App in einem virtuellen X-Display und streamt das Fenster in den Browser.
Es wird keine GPU benoetigt; gerendert wird per Mesa/llvmpipe.

## Schnellstart

Auf dem **Proxmox-Host** als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/BIM-CRAFT-Proxmox/main/install/bimcraft.sh)"
```

Mit festen Ressourcen und CT-ID:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/BIM-CRAFT-Proxmox/main/install/bimcraft.sh)" \
  _ --ctid 150 --cores 4 --memory 6144 --disk 16
```

Alternativ lokal:

```bash
bash install/bimcraft.sh --ctid 150
```

Nach der Installation:

```text
http://<CT-IP>:6080/vnc.html
```

Das noVNC-Passwort steht in der Installationsausgabe und in
`/root/bimcraft-<CTID>-credentials.txt` auf dem Proxmox-Host.

## Voraussetzungen

- Proxmox VE 8.x, Ausfuehrung als root
- x86_64-Host mit Internetzugang
- 4 vCPU, 6144 MB RAM, 16 GB Disk (empfohlen)
  - Minimum: 2 vCPU, 3072 MB RAM, 12 GB Disk
- Debian-12-Standard-Template (wird bei Bedarf automatisch geladen)
- Port `6080/tcp` vom Client zum Container erreichbar
- Keine GPU noetig; Software-Rendering ist ausreichend, aber langsam

## Optionen

| Option | Bedeutung | Default |
| --- | --- | --- |
| `--ctid ID` | Container-ID | naechste freie ID |
| `--hostname NAME` | Container-Hostname | `bimcraft` |
| `--cores N` | vCPU | `4` |
| `--memory MB` | RAM in MB | `6144` |
| `--swap MB` | Swap in MB | `2048` |
| `--disk GB` | Disk in GB | `16` |
| `--storage NAME` | RootFS-Storage | auto, bevorzugt `local-lvm` |
| `--template-store N` | Storage fuer das Template | `local` |
| `--bridge NAME` | Netzwerk-Bridge | `vmbr0` |
| `--ip CIDR` | statische IP, z.B. `192.168.1.50/24` | `dhcp` |
| `--gateway IP` | Gateway bei statischer IP | – |
| `--nameserver IP` | DNS-Server im Container | Host-DNS, sonst `1.1.1.1` |
| `--password PW` | Root-Passwort des CT | zufaellig |
| `--ssh-key PATH` | SSH-Public-Key installieren | – |
| `--novnc-password PW` | noVNC-Passwort setzen | zufaellig/beibehalten |
| `--reset-password` | neues zufaelliges noVNC-Passwort | – |
| `--app-version VER` | BIMCraft-Release | `0.7.0` |
| `--update` | vorhandenen CT neu provisionieren | – |
| `--uninstall` | CT stoppen und zerstoeren | – |
| `--yes` | Bestaetigung bei `--uninstall` ueberspringen | – |
| `--force` | Hostname-Schutz bei `--ctid`/`--uninstall` aus | – |
| `--debug` | `set -x` und erweiterte Fehlerkette | – |

Umgebungsvariablen funktionieren ebenfalls, z.B.:

```bash
CTID=150 CORES=4 RAM=6144 DISK=16 bash install/bimcraft.sh
```

Optional: `BIMCRAFT_WEB_PORT` (Default `6080`) und `BIMCRAFT_VNC_PORT`
(Default `5900`, nur an `127.0.0.1` gebunden) aendern die Ports. Beide muessen
sich unterscheiden.

## Was das Script macht

1. Prueft root-Rechte, `pct`, `pvesh`, `pvesm`, `pveam`, `curl` und x86_64.
2. Sucht einen vorhandenen Container mit Hostname `bimcraft` oder ermittelt
   die naechste freie CT-ID.
3. Waehlt den RootFS-Storage (bevorzugt `local-lvm`) und stellt das
   Debian-12-Template bereit.
4. Erstellt einen **unprivilegierten** LXC mit `onboot=1` und den gewaehlten
   Ressourcen.
5. Installiert im Container Xvfb, openbox, x11vnc, noVNC/websockify sowie die
   Mesa-Software-Rendering-Pakete.
6. Laedt das offizielle BIMCraft-.deb der gewaehlten Version von GitHub
   Releases und prueft es gegen `SHA256SUMS`.
7. Legt den Benutzer `bimcraft`, die Projektverzeichnisse und das
   noVNC-Passwort an.
8. Installiert vier systemd-Units, aktiviert sie und startet sie.
9. Verifiziert Services, HTTP, VNC-Banner, das BIMCraft-Fenster und `onboot`.
10. Schreibt Zugangsdaten nach `/root/bimcraft-<CTID>-credentials.txt`.

## Zugriff und Passwort

- Web-UI: `http://<CT-IP>:6080/vnc.html`
- noVNC-Passwort: Installationsausgabe bzw. Credentials-Datei
- Im Container: `/root/bimcraft-novnc-password` (0600)
- VNC-Passwortdatei: `/etc/bimcraft/vnc.pass` (0600, Besitzer `bimcraft`)

Neues noVNC-Passwort erzeugen:

```bash
bash install/bimcraft.sh --ctid 150 --update --reset-password
```

Eigenes Passwort setzen:

```bash
bash install/bimcraft.sh --ctid 150 --update --novnc-password 'MeinPasswort'
```

Das Root-Passwort des Containers wird nur bei der Neuanlage erzeugt und in der
Credentials-Datei gespeichert, wenn es nicht per `--password` vorgegeben wurde.

## Idempotenz, Update und Entfernen

- Ohne `--ctid` wird ein vorhandener Container mit Hostname `bimcraft`
  wiederverwendet; sonst wird die naechste freie ID belegt.
- Mit `--ctid` auf einen vorhandenen Container wird nur gearbeitet, wenn dessen
  Hostname zu `--hostname` passt. Sonst bricht das Script ab, damit kein
  fremder Container ueberschrieben wird. `--force` hebelt diesen Schutz aus.
- `--update` provisioniert einen vorhandenen Container erneut. Das noVNC-
  Passwort bleibt erhalten, sofern nicht `--reset-password` oder
  `--novnc-password` gesetzt ist.
- `--uninstall` stoppt und zerstoert den Container. Ohne `--yes` ist eine
  interaktive Bestaetigung erforderlich.

```bash
# Update
bash install/bimcraft.sh --ctid 150 --update

# Entfernen
bash install/bimcraft.sh --ctid 150 --uninstall --yes
```

## Neustart-Verhalten

Alle vier Units sind `enabled`, besitzen `Restart=always` und der Container hat
`onboot=1`. Nach einem Reboot des Proxmox-Hosts oder des Containers starten
Xvfb, BIMCraft, x11vnc und noVNC automatisch wieder.

Health-Test auf dem Proxmox-Host:

```bash
chmod +x tests/reboot-test.sh
./tests/reboot-test.sh 150 --reboot
```

Der Test prueft:

- systemd-Status und alle vier Units
- HTTP 200 der noVNC-Oberflaeche
- VNC-Banner (`RFB`)
- BIMCraft-Fenster in Xvfb (`WM_CLASS` enthaelt `bimcraft`)
- laufenden BIMCraft-Prozess
- `onboot: 1`

Bei Fehlern gibt er `systemctl status`, `journalctl` und das Provision-Log aus.

## Architektur

| Komponente | Details |
| --- | --- |
| Container | Debian 12, unprivilegiert, `onboot=1` |
| Display | Xvfb `:99`, 1920x1080x24, GLX |
| Fenstermanager | openbox |
| App | `/usr/bin/bimcraft`, Benutzer `bimcraft` |
| VNC | x11vnc auf `127.0.0.1:5900`, Passwortdatei |
| Web | websockify/noVNC auf `0.0.0.0:6080` |
| Rendering | Mesa/llvmpipe (`LIBGL_ALWAYS_SOFTWARE=1`) |
| App-Argumente | `/etc/default/bimcraft`, Default `--sample` |
| Projektordner | `/home/bimcraft/Projects` |
| Provision-Log | `/var/log/bimcraft-provision.log` |
| Install-Log | `/tmp/bimcraft-install-<Datum>.log` auf dem Host |

Ports:

- `6080/tcp`: noVNC, vom Client erreichbar
- `5900/tcp`: x11vnc, **nur** an `127.0.0.1` gebunden

## Troubleshooting

### Web-UI laedt, aber der Bildschirm bleibt schwarz

```bash
pct exec 150 -- systemctl status bimcraft-app --no-pager -l
pct exec 150 -- journalctl -u bimcraft-app -n 100 --no-pager
pct exec 150 -- bash -c 'DISPLAY=:99 xwininfo -root -tree | head -n 40'
```

Haeufig ist die App noch beim Start oder das Modell wird geladen. Bei
GL-Fehlern helfen mehr vCPU/RAM; Software-Rendering bleibt langsam.

### Kein Fenster, App-Prozess laeuft aber

```bash
pct exec 150 -- pgrep -a -u bimcraft bimcraft
pct exec 150 -- bash -c 'DISPLAY=:99 xprop -root _NET_CLIENT_LIST'
```

`WM_CLASS` sollte `io.github.ipedrax.bimcraft` enthalten.

### Port 6080 nicht erreichbar

```bash
pct exec 150 -- ss -ltnp
pct exec 150 -- curl -I http://127.0.0.1:6080/vnc.html
```

Ist die Proxmox-Firewall (Datacenter/CT) aktiv, muss `6080/tcp` fuer die
gewuenschten Quellen freigegeben werden. Im Container wird bei aktivem `ufw`
automatisch `6080/tcp` geoeffnet; `ufw` ist standardmaessig nicht installiert.

### noVNC-Passwort vergessen

```bash
bash install/bimcraft.sh --ctid 150 --update --reset-password
```

### Template-Download schlaegt fehl

```bash
pveam update
pveam available --section system | grep debian-12
```

Alternativ `--template-store` auf einen Storage mit `vztmpl`-Content setzen.

### DNS/Internet im Container fehlt

```bash
cat /etc/resolv.conf
resolvectl status 2>/dev/null | head -20
pct exec 150 -- cat /etc/resolv.conf
pct exec 150 -- getent hosts deb.debian.org
```

Zeigt die Datei im Container `nameserver 127.0.0.53`, ist der Host-Resolver
gemeint, der im LXC nicht erreichbar ist. Der Installer erkennt das und setzt
automatisch einen passenden Nameserver. Manuell:

```bash
pct set 150 --nameserver 1.1.1.1
pct exec 150 -- sh -c 'printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" > /etc/resolv.conf'
pct exec 150 -- getent hosts deb.debian.org
```

Danach `bash install/bimcraft.sh --ctid 150 --update` erneut ausfuehren.

### SHA-256-Mismatch beim .deb

Das Release-Asset passt nicht zur `SHA256SUMS`-Datei. Pruefe die Version:

```bash
bash install/bimcraft.sh --ctid 150 --update --app-version 0.7.0
```

### Vollstaendige Diagnose

```bash
pct exec 150 -- tail -n 100 /var/log/bimcraft-provision.log
pct exec 150 -- systemctl --failed --no-pager
```

Das Installationsscript gibt bei Fehlern automatisch Befehl, Zeile, Exit-Code,
Aufrufstapel, Unit-Status, Journal und Provision-Log aus.

## Sicherheit

- noVNC laeuft ueber **HTTP ohne TLS**. Nur im vertrauenswuerdigen LAN
  betreiben oder per SSH-Tunnel:

  ```bash
  ssh -L 6080:127.0.0.1:6080 root@<CT-IP>
  # danach: http://127.0.0.1:6080/vnc.html
  ```

  Falls im Container kein SSH-Server laeuft, den Tunnel ueber den
  Proxmox-Host bauen:

  ```bash
  ssh -L 6080:<CT-IP>:6080 root@<PROXMOX-HOST>
  ```

- Der Container ist unprivilegiert; die App laeuft als Benutzer `bimcraft`,
  nicht als root.
- noVNC-Passwort, Credentials-Datei und Install-/Provision-Logs sind auf `0600` gesetzt.
- Der Installer richtet keine Cloud-Dienste ein; die App laeuft lokal im Container.
- Fuer Exposition ausserhalb des LANs einen TLS-Reverse-Proxy vor `6080`
  setzen und die Proxmox-Firewall einschraenken.

## Getestet

- Debian-12-Container mit systemd (Docker): Provisionierung, alle vier Units,
  HTTP 200, VNC-Banner, BIMCraft-Fenster, simulierter Reboot per
  `docker restart`.
- Host-Script mit gemockten `pct`/`pvesh`/`pvesm`/`pveam` gegen den echten
  Container: Reuse-/Update-Pfad zweimal, Neu-Anlage-Pfad, Hostname-Schutz.
- DNS-Fallback: absichtlich defekte `resolv.conf` (`127.0.0.53`) wird erkannt und
  durch einen funktionierenden Nameserver ersetzt.
- `bash -n`, `shellcheck -S warning` und `systemd-analyze verify` sind sauber.

Details und Log-Auszuege: [docs/test-evidence.md](docs/test-evidence.md).

**Noch offen:** Der echte `pct create`-/`pct reboot`-Pfad auf einem
Proxmox-VE-Host wurde in der Build-Umgebung nicht ausgefuehrt. Bitte nach dem
ersten echten Deploy einmal `./tests/reboot-test.sh <CTID> --reboot` laufen
lassen.

## Projektstruktur

```text
install/bimcraft.sh        Host-Installer inkl. eingebettetem Provision-Script
systemd/                   Die vier systemd-Units (Referenz)
tests/reboot-test.sh       Reboot-/Health-Test auf dem Proxmox-Host
docs/test-evidence.md      Testmatrix und Log-Auszuege
docs/superpowers/          Design-Spec und Implementierungsplan
```

## Grenzen

- BIMCraft bleibt eine Desktop-App: eine gemeinsame Sitzung, kein
  Multi-User-Betrieb, keine native Web-Oberflaeche.
- Der MCP-Server von BIMCraft (stdio) wird nicht als Netzwerkdienst
  bereitgestellt.
- Software-Rendering (llvmpipe) ist fuer grosse Modelle deutlich langsamer als
  eine GPU. Fuer GPU-Beschleunigung waere eine VM mit GPU-Passthrough noetig;
  das ist nicht Teil dieses Installers.
- Die Standardversion ist auf `0.7.0` gesetzt; andere Releases ueber
  `--app-version` verwenden, sofern sie als x86_64-.deb vorliegen.

## Upstream

- BIMCraft: <https://github.com/IPedrax/BIMCraft>
- Dieses Installer-Repo: <https://github.com/HatchetMan111/BIM-CRAFT-Proxmox>
