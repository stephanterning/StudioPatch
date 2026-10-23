#!/bin/bash
set -euo pipefail
task_target="/Library/Audio/Plug-Ins/HAL/StudioPatch.driver"
if [[ $EUID != 0 ]]; then echo "Run this script with sudo."; exit 1; fi
if [[ ! -d "$task_target" ]]; then echo "StudioPatch is not installed."; exit 0; fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_target/Contents/Info.plist")" != "se.studiopatch.driver" ]]; then
    echo "Unexpected bundle identifier. No files were removed."; exit 1
fi
rm -rf -- "$task_target"
task_transport="/Library/PrivilegedHelperTools/se.studiopatch.transport"
task_plist="/Library/LaunchDaemons/se.studiopatch.transport.plist"
if [[ -d "$task_transport" && ! -L "$task_transport" && -f "$task_plist" && ! -L "$task_plist" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print Label' "$task_plist")" == se.studiopatch.transport ]]; then
    if launchctl print system/se.studiopatch.transport >/dev/null 2>&1; then
        launchctl bootout system/se.studiopatch.transport
    fi
    rm -f -- "$task_transport/broker" "$task_transport/service.requirement" "$task_plist"
    rmdir "$task_transport"
fi
echo "Removed StudioPatch.driver. Restart the Mac to unload the running driver."
