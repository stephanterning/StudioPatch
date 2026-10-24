#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
echo 'Avsluta Ableton Live innan du kör. Namnen läses in nästa gång Live startar.'
echo 'Uppdaterar StudioPatch från kanalnamnen i macOS.'
echo
bash Scripts/sync-ableton-channel-names.sh --apply
result=$?
echo
if [[ $result -eq 0 ]]; then
    echo 'Klart. Tryck Retur för att stänga.'
else
    echo 'Körningen avbröts. Se felmeddelandet ovan. Tryck Retur för att stänga.'
fi
read -r
exit "$result"
