#!/bin/bash
set -euo pipefail
task_target="/Library/Audio/Plug-Ins/HAL/StudioPatch.driver"
if [[ $EUID != 0 ]]; then echo "Run this script with sudo."; exit 1; fi
if [[ ! -d "$task_target" ]]; then echo "StudioPatch is not installed."; exit 0; fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_target/Contents/Info.plist")" != "se.studiopatch.driver" ]]; then
    echo "Unexpected bundle identifier. No files were removed."; exit 1
fi
rm -rf -- "$task_target"
echo "Removed StudioPatch.driver. Restart the Mac to unload the running driver."
