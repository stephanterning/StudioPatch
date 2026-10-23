#!/bin/bash
set -euo pipefail
if [[ $EUID == 0 ]]; then echo 'Run this as your regular user, without sudo.'; exit 1; fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_binary="$task_root/Dist/StudioPatch.app/Contents/MacOS/StudioPatchService"
codesign --verify --strict "$task_root/Dist/StudioPatch.app"
task_agents="$HOME/Library/LaunchAgents"
task_plist="$task_agents/se.studiopatch.runtime.plist"
mkdir -p "$task_agents" "$HOME/Library/Application Support/StudioPatch"
if [[ -f "$task_plist" ]]; then cp "$task_plist" "$task_plist.previous"; fi
/usr/bin/plutil -create xml1 "$task_plist"
/usr/bin/plutil -insert Label -string se.studiopatch.runtime "$task_plist"
/usr/bin/plutil -insert ProgramArguments -array "$task_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$task_binary" "$task_plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$task_plist"
/usr/bin/plutil -insert KeepAlive -dictionary "$task_plist"
/usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool NO "$task_plist"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "$task_plist"
chmod 600 "$task_plist"
echo 'The background engine is registered for the next login. Restart after installing the driver.'
