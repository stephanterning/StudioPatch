# Core Audio label verification — 2026-10-24

The agreed behavior is in [Preset identity and Core Audio channel labels](PRESET-IDENTITY-AND-LABELS.md). Import/export is excluded.

## Live API probe

`Tools/channel-label-probe.mm` creates two process-private aggregate devices with random test UIDs. It starts no audio and writes channel names only on these disposable devices. Their single member is the existing StudioPatch virtual device. Cleanup clears touched aliases and destroys both aggregates. Existing StudioPatch labels, physical names, default devices and user aggregates are untouched.

Both input and output tests passed:

- Setting an element-name CFString changes the effective name.
- Reading a known manual label and writing it to a second UID copies it independently.
- Writing an empty CFString clears the override.
- Clearing returns to the default and follows subsequent default changes (tested by removing/reinstating only the disposable aggregate's member).
- Input/output listeners using `kAudioObjectPropertyElementWildcard` receive set and clear notifications.
- An explicitly set label equal to the default remains sticky when the default changes. The ordinary getter cannot distinguish it from an automatic name beforehand. The user accepted copying only effective strings that differ from defaults.

Reproduce with an installed, available StudioPatch device with at least one input and output:

```sh
xcrun clang++ -std=c++17 -fobjc-arc -framework Foundation -framework CoreAudio \
  Tools/channel-label-probe.mm -o /tmp/studiopatch-channel-label-probe
/tmp/studiopatch-channel-label-probe 'se.studiopatch.device.v1'
```

Pass the active preset UID instead for the new installation. The probe needs normal Core Audio access; a restricted process sandbox cannot enumerate these devices. JSONL results from this development run are in the ignored `work/label-verification/final-clear-copy-probe.jsonl`.

## Limits and failed experiments

A nested-private-aggregate approach did not supply usable default channel names; it was replaced by the member removal/reinstatement test above. A separate test explicitly destroyed and recreated a private aggregate with the same UID: its aliases did **not** survive. Explicit aggregate deletion is not the native AudioServerPlugIn endpoint lifecycle, so neither that failure nor the passing copy test establishes persistence for StudioPatch preset switching.

No private macOS audio preference keys are used by the implementation. Read-only inspection of those preferences was diagnostic evidence only. No running driver or system audio daemon was restarted for these probes.

## Automated coverage

- Driver: version 1 compatibility and version 2 UID validation; UID changes create new endpoint objects; old clients are retired and muted; defaults do not cross identities; display-name edits retain the same UID/object; configuration reload retains UID.
- Model: unique new identities, stable rename/save identities, physical names read-only, effective HAL names in the matrix, no label dirty marker, no manual labels in newly saved presets, copy/no-copy, read failure before creation, partial write failure with retry, clearing via the HAL writer, fresh default identities and reopening without rewriting the library.
- Runtime: metadata rename does not restart or update routing; changing only UID restarts/reconfigures, including returning to an earlier UID. Existing recovery and routing suites remain in place.

Validation completed: all 8 CTest suites passed; `Scripts/test-runtime.sh` passed with no real HAL entry points in its fake service; all 9 Ableton name-sync tests passed. The expanded runtime run exposed a stale-status race in its watchdog assertion; the test now waits for the new process image as well as a running status, and the full rerun passed.

A matching signed app, service, driver and broker were built in the local ignored `work/preset-label-build/` directory using `STUDIOPATCH_DIST_DIR`. Nothing was installed and the running `Dist/` package was not replaced. Both app and driver passed strict signature verification during packaging.

## Installation acceptance still required

Use the matching signed app/service and driver. The shared transport layout is unchanged. Follow the normal installation process and restart the Mac to load the driver; do not restart `coreaudiod` on this studio machine. Preserve the session/library and the previous signed installation before testing.

1. Create two disposable presets with different UIDs and identical audio formats. Verify only the active virtual device is exposed and the name follows the preset. Check a rename keeps its UID and does not stop audio.
2. Edit input and output labels in each direction between StudioPatch and Audio MIDI Setup. Verify the matrix updates without refresh and no `*` appears. Rename a physical channel externally; verify it is read, not overwritten.
3. Clear a virtual label, change its route, and verify the default follows the route. Leave another manual label intact and verify it stays on its channel.
4. Switch A → B → A. Verify A's latest manual labels return and B remains independent. Repeat after panel/service restart and after reboot. Failure here blocks release of the Core Audio-only ownership design.
5. Reduce and restore exposed channel counts; verify labels on hidden channels return by UID/direction/channel number. Check input and output independently.
6. Save as new with copy, without copy, and cancel. Verify the source is untouched; equal-text aliases intentionally become automatic only in the copied preset.
7. Observe Audio MIDI Setup and the supported DAW during UID/name changes. Check expected device reselection. The Ableton name-sync helper now discovers the active StudioPatch UID; confirm Live has saved that UID's layout before syncing.

The signed build is a candidate for this acceptance run, not a claim that native HAL persistence has already been proven.

## Installation handoff

On 2026-10-24 the user authorized installation before restarting the Mac. The signed candidate was promoted to `Dist/`; the driver and broker were installed on disk, and the user LaunchAgent was registered for next login. StudioPatch and its runtime were stopped. Neither Core Audio nor the running broker was restarted.

Strict signature checks, the service’s match against the installed broker requirement, installed file comparisons and the LaunchAgent executable path all passed. Installation hashes are saved locally in `work/install-preset-labels/installed.json`. Original session/package files and the service registration are backed up under `work/install-preset-labels/20261024-095602/`; system driver/broker backups are under `/Library/Audio/StudioPatch Backups/preset-labels.1Jk625/`.

The pre-reboot effective labels for the legacy UID (46 inputs, 40 outputs) are saved in `work/install-preset-labels/before-reboot-labels.json`. Restart and native UID/label acceptance checks remain pending; installation alone does not verify label persistence.
