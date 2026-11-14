#!/bin/bash
# eth0.sh
# Stellt eine Linux-VM (Ubuntu/Debian) vor dem Umzug VMware -> XCP-ng auf den
# festen Kartennamen "eth0" um (Kernel-Parameter net.ifnames=0), damit die
# Netzwerkkonfiguration nach dem Umzug weiter passt. Optional neuer Hostname.
# Alle Änderungen wirken erst nach dem Neustart.
#
# Aufruf:  sudo bash eth0.sh [-n neuer-hostname] [-p] [-y]
#   -n NAME  zusätzlich den Hostnamen ändern
#   -p       nur prüfen und anzeigen, nichts ändern
#   -y       ohne Rückfragen ausführen (startet NICHT selbst neu)
#
# Sicherung + Rückweg: /root/eth0-sicherung-<datum>/zurueck.sh

set -euo pipefail

NEUNAME=""; NURPRUEFEN=0; JA=0
while getopts "n:py" o; do
  case "$o" in
    n) NEUNAME="$OPTARG" ;;
    p) NURPRUEFEN=1 ;;
    y) JA=1 ;;
    *) echo "Aufruf: sudo bash $0 [-n hostname] [-p] [-y]"; exit 2 ;;
  esac
done

rot()   { printf '\e[31m%s\e[0m\n' "$*"; }
gruen() { printf '\e[32m%s\e[0m\n' "$*"; }
gelb()  { printf '\e[33m%s\e[0m\n' "$*"; }
abbruch() { rot "ABBRUCH: $*"; rot "Es wurde nichts geändert."; exit 1; }
frage() {  # frage "Text" -> 0 bei j/J
  local a
  if [ "$JA" -eq 1 ]; then return 0; fi
  read -r -p "$1 [j/N] " a </dev/tty || true
  [[ "$a" =~ ^[jJ]$ ]]
}

# ---------------------------------------------------------------- Prüfungen
[ "$(id -u)" -eq 0 ] || abbruch "bitte mit sudo starten."
command -v update-grub >/dev/null || abbruch "update-grub fehlt – nur für Ubuntu/Debian gedacht."
[ -f /etc/default/grub ] || abbruch "/etc/default/grub fehlt."

. /etc/os-release
ALTHOST="$(hostname)"
echo "System:   ${PRETTY_NAME:-unbekannt}"
echo "Hostname: $ALTHOST"

# Physische Karten = haben /sys/class/net/<name>/device (wt0, lo, docker, veth nicht)
KARTEN=()
for p in /sys/class/net/*; do
  [ -e "$p/device" ] && KARTEN+=("$(basename "$p")")
done
if [ "${#KARTEN[@]}" -eq 0 ]; then abbruch "keine Netzwerkkarte gefunden."; fi
if [ "${#KARTEN[@]}" -gt 1 ]; then
  abbruch "mehrere Karten (${KARTEN[*]}): Reihenfolge eth0/eth1 wäre nicht sicher – bitte von Hand per MAC-Bindung lösen."
fi
ALT="${KARTEN[0]}"
echo "Karte:    $ALT ($(cat "/sys/class/net/$ALT/address"))"

# GRUB schon gesetzt? grub.d/*.cfg wird nach /etc/default/grub gelesen,
# die letzte GRUB_CMDLINE_LINUX-Zeile gilt.
GRUB_NOETIG=1
LETZTE="$(grep -h '^GRUB_CMDLINE_LINUX=' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null | tail -n 1 || true)"
if [[ "$LETZTE" == *net.ifnames=0* ]]; then
  GRUB_NOETIG=0
elif grep -ls '^GRUB_CMDLINE_LINUX=' /etc/default/grub.d/*.cfg >/dev/null 2>&1; then
  abbruch "GRUB_CMDLINE_LINUX wird in /etc/default/grub.d/ überschrieben – bitte von Hand prüfen."
fi

# Eigene .link-Dateien würden die Benennung übersteuern
if ls /etc/systemd/network/*.link >/dev/null 2>&1; then
  abbruch "es gibt eigene .link-Dateien in /etc/systemd/network – bitte von Hand prüfen."
fi

# Konfigurationsdateien mit dem alten Namen
DATEIEN=()
if [ "$ALT" != "eth0" ]; then
  mapfile -t DATEIEN < <(grep -rlw -- "$ALT" /etc/netplan /etc/network/interfaces /etc/network/interfaces.d \
    /etc/systemd/network /etc/NetworkManager/system-connections 2>/dev/null || true)
  if [ "${#DATEIEN[@]}" -eq 0 ]; then
    abbruch "keine Netzwerkkonfiguration mit '$ALT' gefunden (DHCP per Muster? NetworkManager?) – bitte von Hand prüfen."
  fi
  if grep -Eq '^\s*(match|set-name)\s*:' /etc/netplan/*.yaml 2>/dev/null; then
    abbruch "netplan nutzt match:/set-name: – einfache Umbenennung nicht sicher, bitte von Hand."
  fi
fi

# Weitere Stellen mit dem alten Namen (Firewall o. ä.) – nur Hinweis
WEITERE=()
if [ "$ALT" != "eth0" ]; then
  mapfile -t WEITERE < <(grep -rlw -- "$ALT" /etc/iptables /etc/nftables.conf /etc/ufw /etc/sysctl.conf \
    /etc/sysctl.d /etc/default /etc/rc.local 2>/dev/null | grep -v '^/etc/default/grub$' || true)
fi

# Hostname prüfen
if [ -n "$NEUNAME" ]; then
  [[ "$NEUNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || abbruch "Hostname '$NEUNAME' ungültig (nur a-z, 0-9, -)."
  [ "$NEUNAME" = "$ALTHOST" ] && NEUNAME=""
fi

# ---------------------------------------------------------------- Plan
echo
echo "Geplant:"
NICHTS=1
if [ "$GRUB_NOETIG" -eq 1 ]; then echo "  - GRUB: net.ifnames=0 biosdevname=0 setzen, update-grub"; NICHTS=0
else echo "  - GRUB: schon gesetzt"; fi
if [ "$ALT" != "eth0" ]; then
  for d in "${DATEIEN[@]}"; do echo "  - $d: $ALT -> eth0"; done; NICHTS=0
else echo "  - Karte heißt schon eth0"; fi
if [ -d /etc/cloud/cloud.cfg.d ]; then
  [ -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ] || { echo "  - cloud-init: Netzwerkverwaltung abschalten"; NICHTS=0; }
fi
if [ -n "$NEUNAME" ]; then
  echo "  - Hostname: $ALTHOST -> $NEUNAME (inkl. /etc/hosts)"; NICHTS=0
  [ -d /etc/cloud/cloud.cfg.d ] && echo "  - cloud-init: preserve_hostname: true"
fi
if [ "${#WEITERE[@]}" -gt 0 ]; then
  gelb "  ! '$ALT' steht auch in (wird NICHT geändert, bitte selbst prüfen):"
  for d in "${WEITERE[@]}"; do gelb "      $d"; done
fi

if [ "$NICHTS" -eq 1 ]; then gruen "Nichts zu tun."; exit 0; fi
if [ "$NURPRUEFEN" -eq 1 ]; then gelb "Nur Prüfung (-p) – nichts geändert."; exit 0; fi
if [ "${#WEITERE[@]}" -gt 0 ] && [ "$JA" -eq 1 ]; then
  abbruch "weitere Stellen mit '$ALT' gefunden – mit -y nicht automatisch, bitte ohne -y starten."
fi
frage "Ausführen?" || { gelb "Abgebrochen, nichts geändert."; exit 0; }

# ---------------------------------------------------------------- Sicherung
SICH="/root/eth0-sicherung-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SICH"
NEU=()   # neu angelegte Dateien (für den Rückweg)
cp -a --parents /etc/default/grub /etc/hosts /etc/hostname "$SICH"/
for d in "${DATEIEN[@]}"; do cp -a --parents "$d" "$SICH"/; done

# ---------------------------------------------------------------- Änderungen
# cloud-init darf Netz/Hostname nicht zurückschreiben
if [ -d /etc/cloud/cloud.cfg.d ]; then
  f=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  if [ ! -f "$f" ]; then echo 'network: {config: disabled}' > "$f"; NEU+=("$f"); fi
  if [ -n "$NEUNAME" ]; then
    f=/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
    if [ ! -f "$f" ]; then echo 'preserve_hostname: true' > "$f"; NEU+=("$f"); fi
  fi
fi

# GRUB
if [ "$GRUB_NOETIG" -eq 1 ]; then
  if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' /etc/default/grub
  else
    echo 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"' >> /etc/default/grub
  fi
  update-grub 2>&1 | sed 's/^/    /'
fi

# Netzwerkkonfiguration
for d in "${DATEIEN[@]}"; do
  sed -i -E "s/\b${ALT}\b/eth0/g" "$d"
done
if command -v netplan >/dev/null && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
  netplan get >/dev/null 2>&1 || rot "WARNUNG: netplan meldet einen Fehler in /etc/netplan – vor dem Neustart prüfen!"
fi

# Hostname
if [ -n "$NEUNAME" ]; then
  hostnamectl set-hostname "$NEUNAME"
  if grep -qw -- "$ALTHOST" /etc/hosts; then
    sed -i -E "s/\b${ALTHOST}\b/${NEUNAME}/g" /etc/hosts
  else
    echo "127.0.1.1 $NEUNAME" >> /etc/hosts
  fi
fi

# ---------------------------------------------------------------- Rückweg
{
  echo '#!/bin/bash'
  echo "# Stellt den Stand vor eth0.sh wieder her. Danach neu starten."
  echo 'set -e'
  echo "cp -a '$SICH/etc/.' /etc/"
  for f in "${NEU[@]}"; do echo "rm -f '$f'"; done
  [ -n "$NEUNAME" ] && echo "hostnamectl set-hostname '$ALTHOST'"
  echo 'update-grub'
  echo 'echo "Zurückgestellt. Jetzt neu starten: sudo reboot"'
} > "$SICH/zurueck.sh"
chmod 700 "$SICH/zurueck.sh"

# ---------------------------------------------------------------- Ergebnis
echo
gruen "Fertig. Kontrolle:"
echo "--- GRUB"
grep -H '^GRUB_CMDLINE_LINUX=' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null || true
grep -q 'net.ifnames=0' /boot/grub/grub.cfg 2>/dev/null && echo "    (in /boot/grub/grub.cfg übernommen)" || rot "    net.ifnames=0 NICHT in /boot/grub/grub.cfg!"
for d in "${DATEIEN[@]}"; do
  echo "--- $d"
  diff -u "$SICH$d" "$d" | tail -n +3 || true
done
if [ -n "$NEUNAME" ]; then
  echo "--- Hostname: $(hostname)"
  grep -w -- "$NEUNAME" /etc/hosts
fi
echo
echo "Sicherung: $SICH"
echo "Rückweg:   sudo bash $SICH/zurueck.sh && sudo reboot"
[ -n "$NEUNAME" ] && gelb "Hinweis: Peer-Namen im NetBird-Dashboard von Hand ändern."
echo
echo "Nach dem Neustart prüfen:  ip -br addr ; netbird status"
echo

if [ "$JA" -eq 0 ] && frage "Jetzt neu starten?"; then
  reboot
else
  gelb "Kein Neustart. Wirksam erst nach: sudo reboot"
fi
