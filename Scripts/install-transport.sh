#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_dir="/Library/PrivilegedHelperTools/se.studiopatch.transport"
task_plist="/Library/LaunchDaemons/se.studiopatch.transport.plist"
if [[ $EUID != 0 ]]; then echo 'Run as root.'; exit 1; fi
codesign --verify --strict "$task_root/Dist/StudioPatchBroker"
test -s "$task_root/Dist/service.requirement"
if [[ -L "$task_dir" || -L "$task_plist" ]]; then echo 'Unexpected symlink'; exit 1; fi
if [[ -e "$task_dir" ]]; then
    task_backup="$(mktemp -d '/Library/PrivilegedHelperTools/studiopatch-previous.XXXXXX')"
    ditto "$task_dir" "$task_backup/transport"
    if [[ -f "$task_plist" ]]; then cp "$task_plist" "$task_backup/launchd.plist"; fi
fi
mkdir -p "$task_dir"
install -o root -g wheel -m 755 "$task_root/Dist/StudioPatchBroker" "$task_dir/broker.new"
mv "$task_dir/broker.new" "$task_dir/broker"
install -o root -g wheel -m 644 "$task_root/Dist/service.requirement" "$task_dir/service.requirement"
cat > "$task_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>se.studiopatch.transport</string>
<key>ProgramArguments</key><array>
<string>/Library/PrivilegedHelperTools/se.studiopatch.transport/broker</string>
<string>/Library/PrivilegedHelperTools/se.studiopatch.transport/service.requirement</string>
</array>
<key>MachServices</key><dict><key>se.studiopatch.transport</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
PLIST
chown root:wheel "$task_dir" "$task_plist"
chmod 755 "$task_dir"
chmod 644 "$task_plist"
plutil -lint "$task_plist"
if launchctl print system/se.studiopatch.transport >/dev/null 2>&1; then
    launchctl bootout system/se.studiopatch.transport
fi
launchctl bootstrap system "$task_plist"
echo 'Installed authenticated shared-memory transport broker.'
