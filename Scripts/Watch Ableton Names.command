#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
echo 'Synkar StudioPatch-namn automatiskt när Live är stängt.'
echo 'Låt detta terminalfönster vara öppet. Ctrl-C stoppar bevakningen.'
echo
bash Scripts/sync-ableton-channel-names.sh --watch
