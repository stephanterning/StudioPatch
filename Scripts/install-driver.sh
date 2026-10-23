#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source="$task_root/Dist/StudioPatch.driver"
task_target="/Library/Audio/Plug-Ins/HAL/StudioPatch.driver"
if [[ $EUID != 0 ]]; then
    echo "Run this script with sudo after closing audio applications."
    exit 1
fi
task_replace=false
if [[ ${1:-} == --replace && $# == 1 ]]; then
    task_replace=true
elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--replace]"; exit 1
fi
if [[ -e "$task_target" && "$task_replace" != true ]]; then
    echo "StudioPatch.driver already exists. No files were changed."
    echo "Review/remove the old StudioPatch installation before installing this build."
    exit 1
fi
codesign --verify --strict "$task_source"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_source/Contents/Info.plist")" != "se.studiopatch.driver" ]]; then
    echo "Unexpected bundle identifier. Refusing installation."
    exit 1
fi
mkdir -p /Library/Audio/Plug-Ins/HAL
if [[ -e "$task_target" ]]; then
    if [[ -L "$task_target" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_target/Contents/Info.plist")" != "se.studiopatch.driver" ]]; then
        echo "Unexpected existing driver. No files were changed."; exit 1
    fi
    task_backup_root="/Library/Audio/StudioPatch Backups"
    mkdir -p "$task_backup_root"
    task_backup="$(mktemp -d "$task_backup_root/previous.XXXXXX")"
    mv "$task_target" "$task_backup/StudioPatch.driver"
    echo "Previous driver preserved in: $task_backup"
fi
ditto "$task_source" "$task_target"
chown -R root:wheel "$task_target"
chmod -R go-w "$task_target"
echo "Installed StudioPatch.driver. Restart the Mac to load it."
echo "This script does not restart coreaudiod or change your default audio devices."
