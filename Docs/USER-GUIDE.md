# User guide

This guide explains how to use the StudioPatch control panel. It assumes StudioPatch is already [built and installed](INSTALLATION.md).

## Concepts

- **StudioPatch** is one virtual audio device. Select it as both input and output device in your DAW.
- **To Computer** channels are the virtual device's *inputs*: audio from your interfaces going into the DAW.
- **From Computer** channels are the virtual device's *outputs*: audio from the DAW going out to your interfaces.
- The two directions are completely separate. Nothing played on From Computer is looped back to To Computer.
- The **control panel** (`StudioPatch.app`) only edits the configuration. A **background service** does the actual audio work and keeps running when you close the panel. The service starts at login, and opening the panel starts it if it is not running.

## The window

The **sidebar** on the left holds the virtual device settings and the list of audio interfaces. The **main area** shows the routing matrix for the selected direction, plus status and preset controls at the top.

### Virtual device

- **To Computer / From Computer:** how many channels the StudioPatch device exposes in each direction. Each can be 0–128, but at least one direction must be above zero for audio to run. Counts do not need to be powers of two; for example, 37 inputs and 21 outputs is fine.
- **Sync Source:** the interface whose clock drives the virtual device. Its latency is what StudioPatch reports to your DAW.
- **Sample Rate:** the rates the Sync Source supports. Changing it here, or changing the StudioPatch device's rate in your DAW, asks the Sync Source for that rate; locked interfaces then follow the rate the Sync Source actually reaches. If the Sync Source cannot change, StudioPatch and your DAW stay at the previous rate and you get a message and a notification.
- **Advanced → I/O buffer:** the buffer size (32–1024 samples) StudioPatch uses when talking to the physical interfaces. This is separate from your DAW's buffer size. Smaller values give lower latency. The Advanced section also shows the current software margin and each secondary interface's latency difference relative to the Sync Source.

### Audio interfaces

Each physical interface has:

- A **Use** checkbox to make its channels available for routing.
- A **Sync** column. The Sync Source shows a clock icon. Every other selected interface shows a **lock**:
  - **Locked:** follows the Sync Source when the Sync Source or StudioPatch changes rate. If it cannot follow, routing continues and you get a message and a notification. If you change a locked interface's rate yourself, StudioPatch does not set it back; it reports that the rates are not in sync.
  - **Unlocked:** StudioPatch never changes this interface's sample rate. A mismatch does not block routing; you are responsible for the clock and rate settings.
- **Drift correction** (secondary interfaces only). Leave it **off** when the interface is clocked from the Sync Source, for example over ADAT, word clock or MADI. Turn it **on** only for an interface that runs on its own clock; its routes then go through Apple's drift correction, which resamples them and adds some latency. StudioPatch cannot verify an external clock lock for you.

Clearing **Use** on an interface that has routes asks for confirmation. **Remove** deletes the interface and all its routes, including inactive ones; **Cancel** keeps everything.

## Routing

A small legend above Destination and Source identifies the label colors: blue **Core Audio Label**, green **Interface Label**, and orange **Label Mismatch**.

Use the **To Computer / From Computer** switch to pick a direction. Click a cell in the matrix to connect a source to a destination.

- **One source per destination.** Selecting a new source for a destination replaces the old connection. There is no mixing, summing, gain or other processing.
- **Unlimited fan-out.** One source can feed any number of destinations.
- Channel numbers start at **1**. Real channel names come from each interface's driver (for example Analog 9, ADAT 3, MADI 17).
- Row and column headers stay visible while you scroll. Hovering highlights the row and column under the pointer.
- The **Source** column between each destination and the matrix shows its selected source (for example `UFX III · Analog 1`). It stays visible while scrolling, updates when routing changes, and is blank for unconnected destinations. Saved routes involving an unavailable interface appear grey, like their matrix cells.
- **Device order…** decides which interface's channels appear first in the matrix. This only affects the display and never interrupts audio.

Routing changes are applied automatically while audio is running, without interrupting other channels. Changing channel counts, the sample rate, the Sync Source, the I/O buffer or the set of interfaces restarts the audio engine, which causes a short interruption.

### Collapse channel groups

Click a group band above the source columns or beside the destination rows to
collapse or expand it. Interface groups are inferred from consecutive numbers
with the same original channel-name prefix, separately for each interface and
direction. Your custom labels do not affect grouping. AES and names that cannot
be grouped reliably stay individual. Runs longer than 16 channels have subgroups
of at most 16: for example, UFX III MADI 1–64 contains banks 1–16, 17–32, 33–48
and 49–64. To Computer and From Computer use banks of 16 channel numbers.

A filled square involving a collapsed group means at least one connection exists
inside it; hover for the connection count. Clicking either a filled or empty
group square only expands its groups, on both axes if necessary. It never changes
routing. Once both channels are visible individually, ordinary routing clicks
work as before. Disconnected-interface routes remain grey and unavailable.

Collapsed destination rows show their connection count and an orange count of
label mismatches, when present. Expand the group before copying individual
labels. Individual destination rows still show their exact source name even if
that source's column group is collapsed.

Collapse preferences are remembered separately from routing and do not mark the
preset modified. Hardware preferences follow the interface across presets;
computer-channel preferences belong to the preset's virtual device. Groups use
the available (or last-known, for an unavailable interface) channel inventory.

### Inactive routes

Channel counts and routing are stored separately. If you reduce a channel count, routes to the hidden channels become **inactive**: they are kept but carry no audio. A notice shows how many inactive routes exist. Increasing the count again reactivates them.

## Labels

**Labels…** edits the virtual preset device’s channel names under **To Computer (Core Audio)** and **From Computer (Core Audio)**. Double-click a virtual channel header to select its label, including an unconnected channel.

- **Interface inputs** edits source labels shared by every preset. Double-click a physical input's vertical header to select it. These labels are saved separately in StudioPatch by interface UID, direction and channel number; removing an interface or switching presets does not remove them. Clearing a source label restores the interface and channel name (for example `UFX III · Analog 7`).
- **Interface outputs** provides the same editing for physical outputs. In **From Computer**, double-click an output’s row header to select it. **Destination** shows its physical output label; **Source** shows the connected **From Computer N** and its actual Core Audio label.
- Clearing an interface label, or entering its current interface/channel name, uses the automatic fallback and follows later hardware-name changes.
- When a routed pair differs, **both labels turn orange**. Click the label you want to keep: it is copied to the other side. Clickable orange labels show the copy direction: `← label` in Source and `label →` in Destination. Source channel names have no arrow. Clicking a physical interface label writes the connected Core Audio name and verifies it by readback. Clicking a Core Audio label saves it as the physical channel’s shared StudioPatch alias.
- In **To Computer**, Destination is Core Audio and Source is the interface input. In **From Computer**, Source is Core Audio and Destination is the interface output. Matching interface labels are green and matching Core Audio labels cyan. Unavailable or updating pairs are grey. The tooltip reads **“Label mismatch, click to copy this label to the other side”**.
- Shared channels are updated once, and every affected row recomputes its comparison. Copying to an interface label affects all presets that use that physical channel; copying to Core Audio affects every route using that virtual channel. Other pairs may become orange. Input and output aliases with the same channel number remain independent.
- Source edits and routing changes only recompute this comparison; copying to Core Audio is explicit. During an update or when comparison is unavailable, the source label is grey. Green is shown only after reading a matching name back from Core Audio. Failed writes keep the current name and report an error.
- Core Audio owns the labels. Changes made in Audio MIDI Setup appear in the matrix automatically; changes applied in StudioPatch update Core Audio.
- Edits save when you leave a field, press Return, or close the label editor with **Done** or Escape. Clearing a field removes the manual override and restores the routing-derived name. If saving fails, the editor stays open with your text and an error; press Return or Done to retry.
- Physical interface names are read-only in StudioPatch. The names currently returned by Core Audio are displayed, without a separate original-name history.
- Automatic names combine the connected interface and channel names. Unconnected channels use `To Computer N` or `From Computer N`; multiple destinations have combined names.
- Labels stay on their virtual channel when routing changes. They are not saved with presets and do not add a `*` to the preset name.

Each preset exposes a distinct device UID, named `StudioPatch (<preset name>)`. Renaming or saving an existing preset keeps its identity. Switching presets changes the audio device: audio may stop and your DAW may require you to select the new device.

**Save current as new** asks whether to copy labels, create without labels, or cancel. Only names that differ from their current automatic names are copied. An equal-text manual label becomes automatic in the new preset. Copying is a one-time transfer; later edits are independent. If copying fails, the new preset remains saved and StudioPatch offers retry or discard of the remaining transfer. Keep the panel open until the transfer finishes.

Virtual channel labels are stored only in Core Audio. Physical input and output labels are stored in StudioPatch's separate `source-labels.json` file. Neither kind marks a preset as modified. Older app-owned virtual labels are no longer loaded or migrated. Import/export is not included.

### Copy macOS channel names to Ableton Live

The name sync works while **Live is closed**, without Accessibility permission
or UI automation. It reads names from macOS Core Audio (the names in Audio MIDI
Setup) and updates the existing labels in Live's `Preferences.cfg`. Live reads
those labels on its next launch. By default, only the **active StudioPatch preset** device is
updated; other devices and all non-label settings are preserved.

In StudioPatch, click **Tools** next to **Labels…**, then **Update labels in Ableton**.
The tool is included in the app; Python and Xcode are not needed. It refuses to
run while Ableton is open and creates a verified backup before changing labels.
The window shows the full current device name, including its preset name.

If the device is missing from Ableton's settings, start Live, select that exact
StudioPatch device as its audio input and output, then quit Live and retry.
The settings picker lists detected Live 12 versions, newest first. Select the
version you use, or use **Choose file…** to locate a moved `Preferences.cfg`.
StudioPatch remembers your selection and reports a missing file without creating
a replacement. Normally no extra filesystem permission is needed. If access is
denied, select the file with **Choose file…** and follow any macOS access prompt;
the error message explains the privacy settings if access remains blocked.

The repository also provides optional command-line tools:

- **Manual:** quit Live, then double-click `Scripts/Update Ableton Names.command`.
- **Automatic:** double-click `Scripts/Watch Ableton Names.command` and leave its
  Terminal window open. It checks every ten seconds, waits while Live is running,
  and syncs after Live exits. Ctrl-C stops it. It also picks up changes made in
  StudioPatch while Live remains closed. No login service is installed.

These command-line tools require Python 3 and Xcode Command Line Tools. The Core Audio reader is
compiled on first use. The script does not start or quit Live. Let a manual sync
finish before starting Live. A watcher checks again immediately before replacing
preferences, but there is no atomic lock shared with Live's startup: avoid
launching Live at the exact moment the watcher is writing.

From the repository directory:

```sh
bash Scripts/sync-ableton-channel-names.sh --dry-run   # Preview only (also the default)
bash Scripts/sync-ableton-channel-names.sh --apply     # Back up and write while Live is closed
bash Scripts/sync-ableton-channel-names.sh --apply --enable-all # Also enable all mono/stereo inputs and outputs
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
number. Channel activation is preserved by default. Add `--enable-all` to enable all mono
and stereo inputs and outputs for the target device (by default, the active
StudioPatch preset). It also works with `--dry-run` and `--watch`; it cannot be
combined with `--restore` or `--list`. Routing, buffer sizes, sample rates, dormant
channel labels and other devices are not modified.

**File-format limitation:** Ableton does not document this binary format. The
adapter checks the embedded schemas and device/channel layout, edits only the
UTF-16 label spans and, with `--enable-all`, the existing channel activation bytes, then reparses the result and proves that reversing those
edits reproduces the original file byte for byte. An unsupported schema,
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

Validation: ten focused tests cover L/R and numbered pair naming, Unicode, sparse list IDs, dormant labels,
other-device preservation, exact restore, idempotence, format rejection, backups,
opt-in activation of all mono/stereo inputs and outputs,
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

- Greyed-out routes cannot be removed by clicking them in the matrix, and new routes cannot use unavailable ports. To replace an unavailable source, select a source on an available interface in the same **To Computer** row.
- Every interface selected in the active preset is required, including interfaces with no routed channels. If any is missing, the preset’s virtual StudioPatch device is removed from Core Audio and the panel says which hardware is missing. DAWs see a disconnected audio device.
- When all selected interfaces return and the audio engine and hardware clock are ready, StudioPatch publishes the virtual device again with the same preset UID, routing and channel names. A DAW may require you to select the device again.
- At startup, or when loading a preset whose hardware is missing, the virtual device stays unavailable. An empty interface selection also leaves it unavailable.
- StudioPatch sends one notification when a published device is removed because an interface is missing. Returning, publishing a device and switching presets are not problems and do not notify; the status line shows them.
- Timestamp deviations do not mute, restart or remove a connected interface. StudioPatch reports their values under Advanced; you decide whether the clock configuration needs attention.

## Presets and autosave

Configuration changes are saved automatically and restored the next time you log in or open the panel. Core Audio stores applied label changes independently. There is no Save step for everyday work.

Presets are named snapshots of routing and audio configuration, excluding Core Audio labels:

- The name of the active preset is shown at the top. An asterisk (`*`) means the current configuration differs from it; **Save** updates the preset.
- **Presets…** lets you save the current configuration as a new preset, load, rename, overwrite or delete presets. Loading applies the preset immediately.

On first launch, nothing is routed, so opening StudioPatch never produces sound by itself.

## Status and notifications

The status line at the top shows whether routing is active, the current I/O buffer and sample rate, or why audio is off. Problems that do not affect audio, such as an unreadable settings file or a label that could not be written, are appended to the status line while routing continues. While Core Audio processes a requested change, the previous engine keeps running. A control error is reported and retried without stopping it. If Core Audio rejects the change, the previous configuration stays active; change the setting again or choose **Restart Audio Service** to retry. An applied format change interrupts audio while the new engine starts; if the new engine then cannot start, audio stays off with a message and StudioPatch retries automatically. It does not switch back to the previous configuration by itself.

**Notifications** are sent only for problems: a disconnected interface, a failed format change, audio off because of an error, a Sync Source that could not change rate, and a locked interface that is not in sync. Each problem notifies once while it lasts. Successful changes appear only in the status line. Allow notifications for StudioPatch in System Settings if you want them.

**Restart audio service.** When audio is off, a **Restart audio service** button appears next to the status line. It restarts the StudioPatch background service. Use it if audio stays off although the hardware is connected, for example after a Core Audio error that persists. The same command is in the StudioPatch menu, where you can also use it while audio runs to retry an interface that could not start. Restarting interrupts audio briefly.

If StudioPatch changes the Sync Source rate but Core Audio rejects the format, StudioPatch sets the Sync Source and locked interfaces back once to the rate that is still running. It never sets back a rate that something else changed, and a refusal is reported.

**Clock diagnostics.** Advanced shows each secondary interface's timestamp deviation from the Sync Source. These values come from driver timestamps, not hardware clock-lock status. They do not mute audio, restart the engine or require acknowledgement. StudioPatch routes the samples the connected interfaces supply; configure external clocking and optional drift correction yourself. An unlocked interface's sample-rate mismatch does not prevent routing. No resampling is added automatically.

**Warnings while routing.** StudioPatch starts with what the hardware accepts and tells you about the rest in the status line: a locked interface that is not in sync with the Sync Source, a Sync Source that refused a requested rate (StudioPatch stays at the rate it runs at), a secondary interface that could not start, and routes to channels an interface no longer offers, for example ADAT or MADI channels at double speed. Those routes stay silent. A secondary that could not start is tried again at the next configuration change, when it is reconnected, or when you choose **Restart Audio Service**.

## Interface-specific notes

- **RME (TotalMix):** StudioPatch outputs to an RME interface go to its *software playback* channels. TotalMix still decides which physical outputs they reach.
- **Mixers with USB/FireWire returns** (for example Allen & Heath ZED-R16): the mixer's own return settings decide where StudioPatch outputs end up.

## Using StudioPatch in a DAW

1. Select **StudioPatch** as the input and output device.
2. Pick the sample rate in the DAW or in the panel; the other follows.
3. Set the DAW buffer as usual. It is independent of StudioPatch's I/O buffer.
4. StudioPatch reports its latency to Core Audio, so DAW recording compensation works as with a normal interface. Keep any interface-specific correction you already use for the Sync Source.
