# BIMCraft auf Proxmox – Design

Datum: 2026-10-24
Status: freigegeben (Design), Umsetzung ausstehend
Repo: `HatchetMan111/BIM-CRAFT-Proxmox`

## 1. Ziel

BIMCraft (`https://github.com/IPedrax/BIMCraft`) soll sich auf einem Proxmox-VE-Host
mit einem Einzeiler im Stil der Proxmox VE Community Scripts als LXC installieren
lassen. Die native Desktop-App (Rust/egui) wird im Container headless in Xvfb
gestartet und über noVNC im Browser bedienbar gemacht.

Einzeiler:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BIM-CRAFT-Proxmox/main/install/bimcraft.sh)"
```

## 2. Nicht-Ziele

- Kein Fork und keine Änderung am BIMCraft-Quellcode.
- Kein Build aus Rust-Quellen (es wird das offizielle Release-`.deb` verwendet).
- Kein GPU-Passthrough; 3D läuft über Mesa/llvmpipe (Software-Rendering).
- Kein TLS für noVNC; Zugriff ist für LAN/SSH-Tunnel gedacht.
- Keine VM-Variante (wird im README nur als Alternative beschrieben).

## 3. Architektur

```text
Proxmox-Host
└─ install/bimcraft.sh
   ├─ wählt nächste freie CT-ID (pvesh get /cluster/nextid)
   ├─ lädt Debian-12-Template (falls nötig)
   ├─ erstellt LXC "bimcraft" (unprivilegiert, onboot=1)
   ├─ startet CT und wartet auf Netz/IP
   └─ provisioniert im CT:
      ├─ .deb v0.7.0 von GitHub Releases + SHA-256-Prüfung
      ├─ Xvfb :99 (1920x1080x24, GLX, llvmpipe)
      ├─ openbox + bimcraft (Session-Wrapper)
      ├─ x11vnc auf 127.0.0.1:5900 (Passwort)
      └─ websockify/noVNC auf 0.0.0.0:6080
```

Browser: `http://<CT-IP>:6080/vnc.html`

## 4. Komponenten

### 4.1 Host-Script `install/bimcraft.sh`

- `set -euo pipefail`, `trap ERR` mit vollständiger Fehlerkette.
- Optionen: `--ctid`, `--hostname`, `--cores`, `--memory`, `--swap`, `--disk`,
  `--storage`, `--template-store`, `--bridge`, `--ip`, `--gateway`,
  `--password`, `--ssh-key`, `--novnc-password`, `--reset-password`,
  `--app-version`, `--update`, `--uninstall`, `--yes`, `--debug`, `--help`.
- Umgebungs-Overrides: `CTID`, `CORES`, `RAM`, `DISK`, `BIMCRAFT_VERSION`.
- Idempotenz:
  - Ist ein CT mit Hostname `bimcraft` vorhanden, wird es wiederverwendet.
  - Nur bei Erstanlage wird die nächste freie ID genommen.
  - `--ctid` erzwingt eine konkrete ID (vorhanden = Update, sonst Neuanlage).
  - Vorhandene noVNC-Passwörter bleiben erhalten, außer `--reset-password`
    oder `--novnc-password`.
- `--update` verlangt ein vorhandenes CT und provisioniert nur neu.
- `--uninstall` stoppt und zerstört das CT nach Bestätigung (`--yes` überspringt).
- Log: `/tmp/bimcraft-install-<timestamp>.log` (vollständiges stdout/stderr).
- Fehlerausgabe zusätzlich: `pct config`, `pct status`,
  `systemctl status`, `journalctl -u 'bimcraft-*'`, HTTP-/VNC-Check,
  Hinweis auf `--debug` bzw. `bash -x`.

### 4.2 Provisionierung im Container

- Debian-12-Template, unprivilegiert, `onboot: 1`, `nesting=1`.
- Systempakete: `xvfb x11vnc novnc websockify openbox x11-utils`,
  Mesa/EGL/X11-Bibliotheken, Fonts, `ca-certificates`, `curl`.
- App-User `bimcraft` mit Home `/home/bimcraft`, Projektordner
  `/home/bimcraft/Projects`.
- Release-Download:
  - `https://github.com/IPedrax/BIMCraft/releases/download/v<ver>/bimcraft-<ver>-linux-x86_64.deb`
  - `SHA256SUMS` derselben Release; Prüfung mit `sha256sum -c`.
- noVNC-Passwort: zufällig (12 Zeichen) oder vorgegeben; gespeichert in
  `/etc/bimcraft/vnc.pass` (0600) und als Klartext nur root-lesbar in
  `/root/bimcraft-novnc-password` (0600) für spätere Ausgabe.
- Firewall: falls `ufw` aktiv, `6080/tcp` erlauben; 5900 bleibt localhost.

### 4.3 systemd-Units

| Unit | Aufgabe |
|---|---|
| `bimcraft-xvfb.service` | Xvfb `:99`, 1920x1080x24, GLX |
| `bimcraft-app.service` | Session-Wrapper (openbox + `bimcraft --sample`) |
| `bimcraft-vnc.service` | x11vnc, `-localhost`, Passwortdatei |
| `bimcraft-web.service` | websockify/noVNC auf `0.0.0.0:6080` |

Alle Units: `After=network-online.target`, `Wants=network-online.target`,
`Restart=always`, `RestartSec` 2–5 s, `WantedBy=multi-user.target`, `enabled`.

App-Argumente konfigurierbar über `/etc/default/bimcraft`
(`BIMCRAFT_ARGS="--sample"`).

### 4.4 Repo-Dateien

```text
BIM-CRAFT-Proxmox/
├─ install/bimcraft.sh
├─ systemd/bimcraft-xvfb.service
├─ systemd/bimcraft-app.service
├─ systemd/bimcraft-vnc.service
├─ systemd/bimcraft-web.service
├─ tests/reboot-test.sh
├─ README.md
└─ .gitignore
```

Die Units liegen als Dateien im Repo; das Install-Script schreibt identische
Units in den Container (keine Netzabhängigkeit während der Provisionierung).

## 5. Ressourcen

| Parameter | Default | Minimum |
|---|---|---|
| vCPU | 4 | 2 |
| RAM | 6144 MB | 3072 MB |
| Swap | 2048 MB | – |
| Disk | 16 GB | 12 GB |

Begründung: Software-Rendering der 3D-Ansicht und ~43 MB installierte App;
1–2 GB RAM führen zu OOM/Trägheit.

## 6. Sicherheit

- noVNC-Passwort ist Pflicht; kein anonymer Zugriff.
- x11vnc bindet nur an `127.0.0.1`.
- noVNC ist HTTP ohne TLS: nur LAN; README empfiehlt
  `ssh -L 6080:localhost:6080 root@<CT-IP>`.
- Credentials-Datei auf dem Host: `/root/bimcraft-<CTID>-credentials.txt` (0600)
  mit CT-ID, URL, noVNC-Passwort und ggf. root-Passwort.

## 7. Fehlerbehandlung

- Host-`trap ERR`: Befehl, Zeile, Exit-Code, Funktionsstack, Argumente, Logpfad.
- Provision-`trap ERR`: zusätzlich Unit-Status, Journal der Units, letzte
  Xvfb-/App-Ausgaben.
- `--debug` aktiviert `set -x` auf Host und im Container; das vollständige Log
  bleibt erhalten.
- Fehlermeldungen werden nie auf die letzte Zeile gekürzt.

## 8. Verifikation

Das Install-Script prüft nach der Provisionierung:

1. Alle vier Units sind `active`.
2. `http://127.0.0.1:6080/vnc.html` liefert HTTP 200 **und** die noVNC-Oberfläche
   (Inhaltscheck, damit ein fremder Dienst auf Port 6080 nicht als Erfolg gilt).
3. Port 5900 liefert das VNC-Banner `RFB 003.008`.
4. Im Xvfb existiert ein Fenster mit `WM_CLASS` `io.github.ipedrax.bimcraft`
   (per `xprop`; robust gegen UTF-8-Titel).
5. `onboot: 1` ist gesetzt.

Ausgabe am Ende: CT-ID, Hostname, IP, URL, noVNC-Passwort, Logpfad,
Update-/Uninstall-Hinweis.

## 9. Testplan

| Test | Werkzeug | Nachweis |
|---|---|---|
| Syntax | `bash -n install/bimcraft.sh` | Exit 0 |
| Lint | `shellcheck` | keine Fehler |
| Units | `systemd-analyze verify` | Exit 0 |
| Container-Provisionierung | Debian-12-Container (Docker, systemd) | HTTP 200, VNC-Banner, Fenster |
| Reboot | `tests/reboot-test.sh` auf Proxmox | Units active, HTTP 200 nach Reboot |
| Idempotenz | zweiter Lauf | keine zweite CT-ID, gleiche URL |
| Fehlerpfad | provozierter Fehler | vollständige Kette + Logpfad |

Der echte `pct`-/Reboot-Test ist nur auf einem Proxmox-Host möglich und wird
mit `tests/reboot-test.sh` belegt; in der Entwicklungsumgebung wird die
Container-Provisionierung in Docker getestet.

## 10. Abnahmekriterien

- Einzeiler legt genau einen LXC `bimcraft` mit der nächsten freien ID an.
- Web-UI ist unter `http://<IP>:6080/vnc.html` erreichbar und zeigt BIMCraft.
- Nach `pct reboot` sind App und Web-UI ohne manuellen Eingriff wieder da.
- Ein zweiter Lauf erzeugt kein Duplikat und zerstört keine Daten.
- Fehler liefern die komplette Kette und einen reproduzierbaren `bash -x`-Hinweis.
- README enthält Einzeiler, Optionen, Update, Uninstall, Troubleshooting.
