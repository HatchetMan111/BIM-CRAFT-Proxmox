# BIMCraft Proxmox Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Ein Community-Scripts-konformer Einzeiler installiert BIMCraft als LXC und stellt die native Desktop-App über noVNC im Browser bereit.

**Architecture:** Das Host-Script erzeugt/wiederverwendet einen Debian-12-LXC, prüft die nächste freie CT-ID, installiert das offizielle BIMCraft-`.deb` mit SHA-256-Prüfung und betreibt Xvfb + openbox + App + x11vnc + websockify als systemd-Units. Verifikation und Fehlerkette sind Teil des Scripts.

**Tech Stack:** Bash, Proxmox `pct`/`pvesh`/`pveam`/`pvesm`, Debian 12, systemd, Xvfb, x11vnc, noVNC/websockify, BIMCraft 0.7.0 Release-`.deb`.

**Spec:** `docs/superpowers/specs/2026-10-24-bimcraft-proxmox-design.md`

**Status:** Implementiert und lokal getestet (Docker + gemockte Proxmox-CLI);
echter `pct create`/`pct reboot`-Lauf auf Proxmox VE steht noch aus. Siehe
`docs/test-evidence.md`.

## Global Constraints

- `set -Eeuo pipefail` in Host- und Provision-Script.
- CT-Hostname: `bimcraft`; CT-ID: nächste freie via `pvesh get /cluster/nextid`, außer `--ctid`.
- Defaults: 4 vCPU, 6144 MB RAM, 2048 MB Swap, 16 GB Disk; Minimum 2 / 3072 / 12.
- Web-Port 6080/tcp auf `0.0.0.0`; VNC 5900 nur `127.0.0.1`.
- `onboot: 1`; alle Units `enabled`, `Restart=always`, `After=network-online.target`.
- Keine App-Quellcode-Änderung; nur Release-`.deb` `bimcraft-<ver>-linux-x86_64.deb`.
- Fehler immer mit vollständiger Kette (Befehl, Zeile, Exit-Code, Stack, Log) ausgeben.
- Keine Secrets im Repo; Passwörter nur zur Laufzeit erzeugen.

## Review Focus

- **Erneuter Lauf** darf kein zweites CT anlegen und keine Projektdaten löschen.
- **Abbruch mittendrin** (GitHub down, apt-Fehler) muss die volle Kette und den Logpfad zeigen.
- **Reboot** muss App und Web-UI ohne Login/Handgriff wieder hochbringen.
- **Falsche Ressourcen** (1 vCPU/1 GB) dürfen nicht still zu OOM führen; Minimum + Warnung.
- **Fremder Port 6080** belegt: Script muss den Fehler klar benennen, nicht „HTTP 200" vortäuschen.

---

### Task 1: Repo-Gerüst und systemd-Units

**Files:**
- Create: `.gitignore`
- Create: `systemd/bimcraft-xvfb.service`
- Create: `systemd/bimcraft-app.service`
- Create: `systemd/bimcraft-vnc.service`
- Create: `systemd/bimcraft-web.service`

**Interfaces:**
- Produces: Unit-Namen `bimcraft-xvfb`, `bimcraft-app`, `bimcraft-vnc`, `bimcraft-web`; Pfade `/usr/local/bin/bimcraft-session`, `/etc/default/bimcraft`, `/etc/bimcraft/vnc.pass`.

- [x] **Step 1: `.gitignore` schreiben** (Logs, `.deb`, temporäre Testartefakte).
- [x] **Step 2: Units schreiben** – Xvfb `:99` 1920x1080x24; App mit `DISPLAY=:99`, `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`; VNC mit `-localhost -rfbauth`; Web mit `websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900`.
- [x] **Step 3: Verifizieren:** `systemd-analyze verify systemd/*.service` → Exit 0.

### Task 2: Host-Script – CLI, Logging, Fehlerkette, Prechecks

**Files:**
- Create: `install/bimcraft.sh`

**Interfaces:**
- Produces: Optionen `--ctid --hostname --cores --memory --swap --disk --storage --template-store --bridge --ip --gateway --password --ssh-key --novnc-password --reset-password --app-version --update --uninstall --yes --debug --help`; Log unter `/tmp/bimcraft-install-*.log`.
- Consumes: nichts.

- [x] **Step 1: Kopf, Farben, `msg_*`, `exec > >(tee …)`, `trap 'on_error …' ERR` mit vollständiger Kette schreiben.**
- [x] **Step 2: Argumentparser + Validierung** (Zahlen, IP-CIDR, Architektur x86_64, root, `pct/pvesh/pvesm/pveam`).
- [x] **Step 3: Test:** `bash -n install/bimcraft.sh`; `bash install/bimcraft.sh --help` (als Nicht-root nur Hilfe) → Exit 0; unbekannte Option → Exit 1 mit Usage.

### Task 3: Host-Script – CT finden/erstellen/starten

**Files:**
- Modify: `install/bimcraft.sh`

**Interfaces:**
- Produces: `find_existing_ct`, `ensure_template`, `create_ct`, `wait_for_ip`; Variablen `CTID`, `REUSE`, `CT_IP`, `TEMPLATE_VOLID`, `STORAGE`.
- Consumes: geparste Optionen aus Task 2.

- [x] **Step 1: CT per Hostname `bimcraft` suchen; sonst `pvesh get /cluster/nextid`.**
- [x] **Step 2: RootFS-Storage erkennen (`pvesm status -content rootdir`, bevorzugt `local-lvm`), Template laden.**
- [x] **Step 3: `pct create` mit `--onboot 1 --unprivileged 1 --features nesting=1`, Netz DHCP/statisch; bei Reuse `pct set --onboot 1` und starten.**
- [x] **Step 4: Auf IP und DNS im Gast warten (max. ~3 Min).**
- [x] **Step 5: Test:** `bash -n`; Funktionen mit `bash -c 'source <(sed -n …)'`? Praktisch: `shellcheck`.

### Task 4: Provision-Script im Container

**Files:**
- Modify: `install/bimcraft.sh` (embedded heredoc `PROVISION_SCRIPT`)

**Interfaces:**
- Produces: installiertes `/usr/bin/bimcraft`, User `bimcraft`, `/home/bimcraft/Projects`, Units, `/etc/default/bimcraft`, `/etc/bimcraft/vnc.pass`, `/root/bimcraft-novnc-password`.
- Consumes: Env `BIMCRAFT_VERSION`, `BIMCRAFT_NOVNC_PASSWORD`, `BIMCRAFT_DEBUG`, `BIMCRAFT_WEB_PORT`, `BIMCRAFT_VNC_PORT`.

- [x] **Step 1: Pakete installieren** (`xvfb x11vnc novnc websockify openbox x11-utils mesa/EGL/X11 libs`).**
- [x] **Step 2: `.deb` + `SHA256SUMS` laden, `sha256sum -c`, `apt-get install ./…deb`.**
- [x] **Step 3: User/Ordner/Passwort anlegen; Session-Wrapper und Units schreiben; `systemctl enable --now`.**
- [x] **Step 4: Lokal im CT prüfen:** Units active, HTTP 200, VNC-Banner `RFB`, Fenster `BIMCraft`.**
- [x] **Step 5: Test:** Provision-Script in Debian-12-Docker mit systemd ausführen (siehe Task 6).

### Task 5: Host-Verifikation, Ausgabe, Update/Uninstall

**Files:**
- Modify: `install/bimcraft.sh`

**Interfaces:**
- Produces: `verify_installation`, `print_summary`, `do_uninstall`; Credentials `/root/bimcraft-<CTID>-credentials.txt` (0600).
- Consumes: `CTID`, `CT_IP`, Provision-Ergebnis.

- [x] **Step 1: Poll auf HTTP 200 (`/vnc.html`), VNC-Banner, Fenster, `systemctl is-active`, `onboot`.**
- [x] **Step 2: noVNC-Passwort aus dem CT lesen, Credentials schreiben, finale URL/CT-ID/Log ausgeben.**
- [x] **Step 3: `--update` (nur vorhandenes CT) und `--uninstall` (Bestätigung/`--yes`, `pct destroy`) implementieren.**
- [x] **Step 4: Test:** `--help`-Output prüfen; `--uninstall` ohne CT → klare Fehlermeldung.

### Task 6: README und Test-Nachweis

**Files:**
- Create: `README.md`
- Create: `tests/reboot-test.sh`
- Create: `docs/test-evidence.md`

**Interfaces:**
- Produces: Einzeiler, Optionstabelle, Update/Uninstall, Troubleshooting, Reboot-Testscript, dokumentierte lokale Testergebnisse.

- [x] **Step 1: README mit Einzeiler `bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BIM-CRAFT-Proxmox/main/install/bimcraft.sh)"`, URL, Passwort-Hinweis, Grenzen (HTTP/Software-Rendering).**
- [x] **Step 2: `tests/reboot-test.sh`:** `pct reboot`, warten, Units/HTTP/VNC/Fenster prüfen, Log schreiben.
- [x] **Step 3: Docker-Test** (Debian 12 + systemd): Provision-Script ausführen, `curl`/VNC/Fenster prüfen, Container rebooten, erneut prüfen; Ausgabe in `docs/test-evidence.md` festhalten.**
- [x] **Step 4: `shellcheck install/bimcraft.sh tests/reboot-test.sh`; `bash -n`; `systemd-analyze verify`.**
- [x] **Step 5: Bekannte Abweichungen dokumentieren:** echter `pct`/Proxmox-Reboot-Test nur auf Host möglich.

## Self-Review

- Spec-Abdeckung: Installer, App-Install, Web-UI, Reboot, Idempotenz, Fehlerkette, Verifikation, README, Test – je eine Task.
- Platzhalter: keine; konkrete Pfade, Units und Prüfkommandos.
- Typen/Interfaces: Unit-Namen und Pfade in Task 1/4/5 identisch; `CTID`/`CT_IP` durchgängig.
- Review Focus: Idempotenz (Task 3/5), Fehlerkette (Task 2), Reboot (Task 1/6), Ressourcen (Task 2), Portkonflikt (Task 5).
