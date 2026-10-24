# User guide

This guide explains how to use the StudioPatch control panel. It assumes StudioPatch is already [built and installed](INSTALLATION.md).

## Concepts

- **StudioPatch** is one virtual audio device. Select it as both input and output device in your DAW.
- **To Computer** channels are the virtual device's *inputs*: audio from your interfaces going into the DAW.
- **From Computer** channels are the virtual device's *outputs*: audio from the DAW going out to your interfaces.
- The two directions are completely separate. Nothing played on From Computer is looped back to To Computer.
- The **control panel** (`StudioPatch.app`) only edits the configuration. A **background service** does the actual audio work and keeps running when you close the panel. The service starts at login, and opening the panel starts it if it is not running.

## The window

The **sidebar** on the left holds the virtual device settings and the list of audio interfaces. The **main area** shows the routing matrix (or channel list) for the selected direction, plus status and preset controls at the top.

### Virtual device

- **To Computer / From Computer:** how many channels the StudioPatch device exposes in each direction. Each can be 0–128, but at least one direction must be above zero for audio to run. Counts do not need to be powers of two; for example, 37 inputs and 21 outputs is fine.
- **Sync Source:** the interface whose clock drives the virtual device. Its latency is what StudioPatch reports to your DAW.
- **Sample Rate:** the rates the Sync Source supports. Changing it here, or changing the StudioPatch device's rate in your DAW, updates the Sync Source and all locked interfaces.
- **Advanced → I/O buffer:** the buffer size (32–1024 samples) StudioPatch uses when talking to the physical interfaces. This is separate from your DAW's buffer size. Smaller values give lower latency. The Advanced section also shows the current software margin and each secondary interface's latency difference relative to the Sync Source.

### Audio interfaces

Each physical interface has:

- A **Use** checkbox to make its channels available for routing.
- A **Sync** column. The Sync Source shows a clock icon. Every other selected interface shows a **lock**:
  - **Locked:** StudioPatch sets this interface to the Sync Source's sample rate.
  - **Unlocked:** StudioPatch never changes this interface's sample rate. If it does not match, audio stays muted until you fix the rate or lock the interface.
- **Drift correction** (secondary interfaces only). Leave it **off** when the interface is clocked from the Sync Source, for example over ADAT, word clock or MADI. Turn it **on** only for an interface that runs on its own clock; its routes then go through Apple's drift correction, which resamples them and adds some latency. StudioPatch cannot verify an external clock lock for you.

Clearing **Use** on an interface that has routes asks for confirmation. **Remove** deletes the interface and all its routes, including inactive ones; **Cancel** keeps everything.

## Routing

Use the **To Computer / From Computer** switch to pick a direction. Click a cell in the matrix to connect a source to a destination.

- **One source per destination.** Selecting a new source for a destination replaces the old connection. There is no mixing, summing, gain or other processing.
- **Unlimited fan-out.** One source can feed any number of destinations.
- Channel numbers start at **1**. Real channel names come from each interface's driver (for example Analog 9, ADAT 3, MADI 17).
- Row and column headers stay visible while you scroll. Hovering highlights the row and column under the pointer.
- **Channel list** shows the same routing as a list with a menu per destination, which can be easier for large setups.
- **Device order…** decides which interface's channels appear first in the matrix and list. This only affects the display and never interrupts audio.

Routing changes are applied automatically while audio is running, without interrupting other channels. Changing channel counts, the sample rate, the Sync Source, the I/O buffer or the set of interfaces restarts the audio engine, which causes a short interruption.

### Inactive routes

Channel counts and routing are stored separately. If you reduce a channel count, routes to the hidden channels become **inactive**: they are kept but carry no audio. A notice shows how many inactive routes exist. Increasing the count again reactivates them.

## Labels

**Labels…** edits the virtual preset device’s **To Computer** and **From Computer** channel names. Double-click a virtual channel header to select its label, including an unconnected channel.

- Core Audio owns the labels. Changes made in Audio MIDI Setup appear in the matrix automatically; changes applied in StudioPatch update Core Audio.
- Edit a field and choose **Apply** (or press Return). Applying an empty field removes the manual override and restores the routing-derived name.
- Physical interface names are read-only in StudioPatch. The names currently returned by Core Audio are displayed, without a separate original-name history.
- Automatic names combine the connected interface and channel names. Unconnected channels use `To Computer N` or `From Computer N`; multiple destinations have combined names.
- Labels stay on their virtual channel when routing changes. They are not saved with presets and do not add a `*` to the preset name.

Each preset exposes a distinct device UID, named `StudioPatch (<preset name>)`. Renaming or saving an existing preset keeps its identity. Switching presets changes the audio device: audio may stop and your DAW may require you to select the new device.

**Save current as new** asks whether to copy labels, create without labels, or cancel. Only names that differ from their current automatic names are copied. An equal-text manual label becomes automatic in the new preset. Copying is a one-time transfer; later edits are independent. If copying fails, the new preset remains saved and StudioPatch offers retry or discard of the remaining transfer. Keep the panel open until the transfer finishes.

Older app-owned labels are migrated when their preset is activated. Original files are backed up with a `.before-core-audio-labels` suffix; labels not mapped to currently exposed virtual channels remain in those backups. Existing different Core Audio names take precedence. Import/export is not included.

### Copy macOS channel names to Ableton Live

The name sync works while **Live is closed**, without Accessibility permission
or UI automation. It reads names from macOS Core Audio (the names in Audio MIDI
Setup) and updates the existing labels in Live's `Preferences.cfg`. Live reads
those labels on its next launch. By default, only the **active StudioPatch preset** device is
updated; other devices and all non-label settings are preserved.

- **Manual:** quit Live, then double-click `Scripts/Update Ableton Names.command`.
- **Automatic:** double-click `Scripts/Watch Ableton Names.command` and leave its
  Terminal window open. It checks every ten seconds, waits while Live is running,
  and syncs after Live exits. Ctrl-C stops it. It also picks up changes made in
  StudioPatch while Live remains closed. No login service is installed.

Python 3 and Xcode Command Line Tools are required. The Core Audio reader is
compiled on first use. The script does not start or quit Live. Let a manual sync
finish before starting Live. A watcher checks again immediately before replacing
preferences, but there is no atomic lock shared with Live's startup: avoid
launching Live at the exact moment the watcher is writing.

From the repository directory:

```sh
bash Scripts/sync-ableton-channel-names.sh --dry-run   # Preview only (also the default)
bash Scripts/sync-ableton-channel-names.sh --apply     # Back up and write while Live is closed
bash Scripts/sync-ableton-channel-names.sh --watch     # Automatic sync every 10 seconds
bash Scripts/sync-ableton-channel-names.sh --list      # macOS device UIDs and channel names
bash Scripts/sync-ableton-channel-names.sh --restore "/path/to/backup.cfg"
```

Use `--device-uid "UID"` to target another device from `--list`. Device identity is
matched by UID, not display name. `--preferences "/path/to/Preferences.cfg"`
selects an explicit file. Otherwise the version is read from the installed
`/Applications/Ableton Live 12 Suite.app`; `--live-app` can select another app
location. Only Live 12 versions with the recognized embedded schemas are accepted.

Matching L/R pairs such as `Timeline L` and `Timeline R` produce the stereo label
`Timeline` and **empty mono labels**. A shared parenthetical qualifier is preserved:
`A&H Master L (analog)` / `A&H Master R (analog)` becomes `A&H Master (analog)`.
Numbered pairs with an identical prefix keep their mono names and shorten the
stereo name: `Analog 7` / `Analog 8` becomes `Analog 7/8`, and
`UFX III · MADI 9` / `UFX III · MADI 10` becomes `UFX III · MADI 9/10`.
Other pairs keep their Core Audio mono names and combine the names with ` / `
for stereo, or use one name when identical. A missing driver name uses the channel
number. Enabled/disabled channels, routing, buffer sizes, sample rates, dormant
channel labels and other devices are not modified.

**File-format limitation:** Ableton does not document this binary format. The
adapter checks the embedded schemas and device/channel layout, edits only the
UTF-16 label spans, then reparses the result and proves that reversing those
string edits reproduces the original file byte for byte. An unsupported schema,
odd channel count, missing device or changed channel count stops the write. If
channel counts changed, select the device in Live and quit once so Live can save
its new layout, then sync again.

A complete original preferences backup is saved and verified before each change
under `~/Library/Application Support/AbletonChannelNames/Backups/`. Writes use an
atomic file replacement after rechecking that Live is closed and preferences
have not changed. Repeated runs with identical names do not rewrite or back up.
`--restore` restores **only the target device's active labels** from a `.cfg`
backup, preserving subsequent changes to other settings; it makes another backup
first. Specify `--device-uid` for restoration; it requires the same saved channel counts. Stop the watcher before restoring,
or it will copy the Core Audio names back on its next pass.

Validation: nine focused tests cover L/R and numbered pair naming, Unicode, sparse list IDs, dormant labels,
other-device preservation, exact restore, idempotence, format rejection, backups,
refusal to overwrite a concurrent save or write after Live starts, and discovery of the active preset UID. A copy of
real Live 12.4.7 preferences parsed 101 devices and updated 129 StudioPatch mono
and stereo labels; restoring reproduced the original bytes exactly.

On 2026-10-24 the script updated the actual preferences while Live was closed,
with a verified backup. Live 12.4.7 then started successfully and displayed all
69 input labels (46 mono + 23 stereo) and 60 output labels (40 mono + 20 stereo)
in Input Config and Output Config. Disabled outputs 27–30 remained disabled;
96 kHz, 256 samples and five-sample error compensation remained unchanged.
The Main Out chooser also displayed the new stereo name. Automatic repeated
operation across a real exit/start cycle and restore into a real Live session
have not been exercised; their underlying file operations have automated tests.

## Unplugged interfaces

If a selected interface disappears (unplugged, powered off), it stays in the list and matrix, greyed out, with its last known channels and labels.

- You can remove existing routes to and from it, but not add new ones.
- Audio is muted while a selected interface is missing, and the panel says which one.
- When the same interface returns, StudioPatch picks it up automatically and audio resumes.

## Presets and autosave

Configuration changes are saved automatically and restored the next time you log in or open the panel. Core Audio stores applied label changes independently. There is no Save step for everyday work.

Presets are named snapshots of routing and audio configuration, excluding Core Audio labels:

- The name of the active preset is shown at the top. An asterisk (`*`) means the current configuration differs from it; **Save** updates the preset.
- **Presets…** lets you save the current configuration as a new preset, load, rename, overwrite or delete presets. Loading applies the preset immediately.

On first launch, nothing is routed, so opening StudioPatch never produces sound by itself.

## Status and notifications

The status line at the top shows whether routing is active, the current I/O buffer and sample rate, or why audio is muted. StudioPatch also sends macOS notifications when the audio format changes, when a change fails, or when audio is muted. Allow notifications for StudioPatch in System Settings if you want them.

**Secondary interface muted: clock alignment was lost.** StudioPatch detected that a secondary interface drifted away from the Sync Source and muted it to avoid out-of-sync audio. Check the digital clock connection, then restart the service:

```sh
launchctl kickstart -k gui/$(id -u)/se.studiopatch.runtime
```

**Automatic recovery stopped.** The service already restarted itself once in the last ten minutes. Fix the underlying device problem, then reopen the panel to start the service again.

## Interface-specific notes

- **RME (TotalMix):** StudioPatch outputs to an RME interface go to its *software playback* channels. TotalMix still decides which physical outputs they reach.
- **Mixers with USB/FireWire returns** (for example Allen & Heath ZED-R16): the mixer's own return settings decide where StudioPatch outputs end up.

## Using StudioPatch in a DAW

1. Select **StudioPatch** as the input and output device.
2. Pick the sample rate in the DAW or in the panel; the other follows.
3. Set the DAW buffer as usual. It is independent of StudioPatch's I/O buffer.
4. StudioPatch reports its latency to Core Audio, so DAW recording compensation works as with a normal interface. Keep any interface-specific correction you already use for the Sync Source.
