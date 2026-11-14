# Linux-Helfer

Kleine Hilfsskripte von SIPPICOM IT-Solutions für Linux-Server (Ubuntu/Debian),
gedacht zum Abruf direkt an der Konsole.

## eth0.sh — fester Kartenname vor dem Umzug auf einen anderen Hypervisor

Linux benennt die Netzwerkkarte nach der virtuellen Hardware: auf VMware z. B.
`ens33` oder `ens192`, auf XCP-ng `enX0`. Nach einem Umzug passt die
Netzwerkkonfiguration nicht mehr und die VM ist nicht erreichbar.

Das Skript stellt die VM **vor dem Umzug** auf den festen Namen `eth0` um:

- erkennt die Netzwerkkarte selbst (nur VMs mit **einer** Karte)
- setzt `net.ifnames=0 biosdevname=0` in GRUB
- ersetzt den alten Namen in netplan bzw. `/etc/network/interfaces`
- schaltet die Netzwerkverwaltung von cloud-init ab, damit sie nichts zurückschreibt
- ändert auf Wunsch den Hostnamen (inkl. `/etc/hosts`)
- legt eine Sicherung samt Rückweg-Skript unter `/root/eth0-sicherung-<datum>/` an

Es funktioniert auch **nach** einem Umzug (z. B. `enX0` → `eth0`). Das lohnt
sich: Die `xe-guest-utilities` aus den Ubuntu-Paketquellen melden die IP nur
bei klassischen Namen wie `eth0` an XCP-ng/Xen Orchestra, bei `enX0` bleibt
die Anzeige leer.

Die Änderungen wirken erst nach dem Neustart. Bei Unklarheiten (mehrere Karten,
netplan mit `match:`/`set-name:`, eigene `.link`-Dateien …) bricht es ab, ohne
etwas zu ändern.

### Aufruf

```bash
curl -fsSL https://raw.githubusercontent.com/Sippicom-IT-SOLUTIONS/linux-helfer/main/eth0.sh -o eth0.sh
sudo bash eth0.sh -p                 # nur prüfen, nichts ändern
sudo bash eth0.sh                    # umstellen (fragt vorher nach)
sudo bash eth0.sh -n neuer-name      # zusätzlich Hostnamen ändern
```

| Schalter | Wirkung |
|---|---|
| `-p` | nur prüfen und anzeigen |
| `-n NAME` | Hostnamen ändern |
| `-y` | ohne Rückfragen, startet nicht selbst neu |

Nach dem Neustart: `ip -br addr` — die Karte heißt `eth0` und hat die bisherige IP.

**Hinter einer SSL-Inspektion** (Proxy/DNS-Filter, der HTTPS aufbricht) scheitert
`curl` mit Fehler 60, solange dessen Root-Zertifikat auf dem Server fehlt. Dann
die Ausnahme im Filter eintragen oder das Root-Zertifikat einspielen.

### Nach dem Umzug auf XCP-ng

```bash
sudo apt install -y xe-guest-utilities   # Gasttools: IP, Speicher, sauberes Herunterfahren
sudo apt purge -y open-vm-tools          # VMware-Tools entfernen
```

Das Skript weist am Ende selbst darauf hin, wenn etwas davon fehlt.

### Zurück

```bash
sudo bash /root/eth0-sicherung-<datum>/zurueck.sh && sudo reboot
```

**Vorher immer einen Snapshot der VM anlegen und die Konsole des Hypervisors
bereithalten** — falls das Netz nach dem Neustart nicht kommt, geht es nur dort weiter.
