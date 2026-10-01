#!/bin/bash
SRC=/opt/fhem-backup
MOUNTROOT=/mnt/fritznas
DST=$MOUNTROOT/FHEMbackup/pi-haupt
CFGSRC=/opt/fhem-cfg-history
CFGDST=$MOUNTROOT/cfg
LOG=/var/log/fhem-backup-sync.log
NOTIFY=/usr/local/bin/fhem-backup-notify.sh

echo "$(date '+%d.%m.%Y %H:%M:%S') Sync Start" >> "$LOG"

if ! ls "$DST" > /dev/null 2>&1; then
  echo "$(date '+%d.%m.%Y %H:%M:%S') FEHLER: NAS nicht erreichbar" >> "$LOG"
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: NAS nicht erreichbar"
  exit 1
fi

NEWEST=$(ls -1t "$SRC"/FHEM-*.tar.gz 2>/dev/null | head -1)
if [ -z "$NEWEST" ]; then
  echo "$(date '+%d.%m.%Y %H:%M:%S') FEHLER: kein Archiv gefunden" >> "$LOG"
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: kein Archiv gefunden"
  exit 1
fi
BASE=$(basename "$NEWEST")

ls -1t "$DST"/FHEM-*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm
echo "$(date '+%d.%m.%Y %H:%M:%S') Vorab-Aufraeumen OK, frei: $(df -h "$DST" | tail -1 | awk '{print $4}')" >> "$LOG"

RC=1
for VERSUCH in 1 2 3; do
  rsync -t --inplace --bwlimit=6000 "$NEWEST" "$DST"/ >> "$LOG" 2>&1
  RC=$?
  echo "$(date '+%d.%m.%Y %H:%M:%S') rsync $BASE Versuch $VERSUCH RC=$RC" >> "$LOG"
  if [ $RC -eq 0 ]; then
    break
  fi
  echo "$(date '+%d.%m.%Y %H:%M:%S') warte 20s vor erneutem Versuch" >> "$LOG"
  sleep 20
done
if [ $RC -ne 0 ]; then
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: rsync RC=$RC bei $BASE nach 3 Versuchen"
  exit $RC
fi

MDL=$(md5sum "$NEWEST" | cut -d' ' -f1)
MDR=$(md5sum "$DST/$BASE" | cut -d' ' -f1)
if [ "$MDL" != "$MDR" ]; then
  echo "$(date '+%d.%m.%Y %H:%M:%S') FEHLER: Pruefsumme falsch, loesche Kopie" >> "$LOG"
  rm -f "$DST/$BASE"
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: Pruefsumme falsch bei $BASE"
  exit 2
fi
echo "$(date '+%d.%m.%Y %H:%M:%S') Pruefsumme OK" >> "$LOG"

mkdir -p "$DST/cfg-history"
rsync -a --checksum "$CFGSRC"/ "$DST/cfg-history/" >> "$LOG" 2>&1
RC2=$?
if [ $RC2 -ne 0 ]; then
  echo "$(date '+%d.%m.%Y %H:%M:%S') FEHLER: cfg-history Sync RC=$RC2" >> "$LOG"
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: cfg-history Sync"
else
  echo "$(date '+%d.%m.%Y %H:%M:%S') cfg-history synced" >> "$LOG"
fi

mkdir -p "$CFGDST"
rsync -t --checksum /opt/fhem/fhem.cfg "$CFGDST"/ >> "$LOG" 2>&1
RC3=$?
if [ $RC3 -ne 0 ]; then
  echo "$(date '+%d.%m.%Y %H:%M:%S') FEHLER: fhem.cfg Sync RC=$RC3" >> "$LOG"
  "$NOTIFY" "FHEM-Backup Haupt-Pi FEHLER: fhem.cfg Sync"
else
  echo "$(date '+%d.%m.%Y %H:%M:%S') fhem.cfg synced nach $CFGDST" >> "$LOG"
fi

ls -1t "$SRC"/FHEM-*.tar.gz 2>/dev/null | tail -n +3 | xargs -r rm
echo "$(date '+%d.%m.%Y %H:%M:%S') Aufraeumen OK" >> "$LOG"
exit 0
