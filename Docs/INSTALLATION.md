# Installation

StudioPatch has no prebuilt releases. You build it from source, sign it with your own Apple certificate and install three parts: a Core Audio driver, a privileged broker and a per-user background service.

> **Read this first.** The driver runs inside Apple's Core Audio daemon and the broker runs as root. Review the scripts in `Scripts/` before running them with `sudo`. Save your work and quit all audio applications before installing or updating. Never disable SIP or other macOS security features to make the driver load; investigate signing and logs instead.

## Requirements

- macOS 14 Sonoma or later. Development and testing have been done on Apple Silicon.
- Xcode or the Xcode Command Line Tools (Swift, clang), CMake 3.20 or later, and Python 3.
- An **Apple code-signing certificate** with its private key in your login Keychain: *Apple Development* or *Developer ID Application*. A free Apple Developer account can create an Apple Development certificate in Xcode → Settings → Accounts.
- An administrator account.

Ad hoc signing is not supported. macOS ties microphone permission and notifications to the signing identity, and the broker only accepts a service that matches a certificate-based signing requirement.

## 1. Choose a signing identity

List the identities available on your Mac:

```sh
security find-identity -v -p codesigning
```

Then either export the identity for the current shell:

```sh
export STUDIOPATCH_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID1234)"
```

or store it (name or SHA-1 fingerprint) in `Scripts/signing-identity.txt`. That file is ignored by Git. Never commit private keys.

## 2. Build

From the repository root:

```sh
bash Scripts/build.sh
```

Intermediate files go to `build/` (set `STUDIOPATCH_BUILD_DIR` to use another directory). The build compiles everything, runs the test suites and signs the results into `Dist/`:

- `Dist/StudioPatch.app` (control panel, with `StudioPatchService` inside)
- `Dist/StudioPatch.driver`
- `Dist/StudioPatchBroker` and `Dist/service.requirement`
- `Dist/patch-inspect`

Building installs nothing and does not touch Core Audio. You can open `Dist/StudioPatch.app` without installing anything else to explore the interface, edit routing and save presets; audio stays off until the driver is installed.

The build is not notarized. Passing signature checks does not prove that Core Audio will load the driver.

## 3. Install

Keep your clone in a permanent location. The background service is registered to run directly from `Dist/StudioPatch.app` in your clone.

```sh
sudo bash Scripts/install-transport.sh     # broker (LaunchDaemon se.studiopatch.transport)
sudo bash Scripts/install-driver.sh        # Core Audio driver
bash Scripts/install-service.sh            # background service, as your normal user (no sudo)
```

Then **restart the Mac**. The installers never restart Core Audio themselves.

After the restart:

1. Open `Dist/StudioPatch.app` and allow microphone access when asked. macOS requires this permission for any app that reads audio inputs, and the panel and service share it.
2. Select your interfaces, a Sync Source and some routes. See the [user guide](USER-GUIDE.md).
3. Select **StudioPatch** in your DAW and test input and output separately at a low level.

## Updating

Quit audio applications, rebuild, then reinstall the components that changed. When in doubt, reinstall all three, because the driver, broker and service share a memory layout and must match.

```sh
bash Scripts/build.sh
sudo bash Scripts/install-transport.sh
sudo bash Scripts/install-driver.sh --replace
bash Scripts/install-service.sh
```

Restart the Mac if the driver changed. `--replace` moves the previous driver to `/Library/Audio/StudioPatch Backups/`.

If only the app or service changed, rebuilding is enough: restart the service with

```sh
launchctl kickstart -k gui/$(id -u)/se.studiopatch.runtime
```

**If you changed signing identity**, always reinstall the broker as well. It stores the service's signing requirement and will reject a service signed with a different certificate. The first launch after a certificate change may ask for microphone permission again.

## Uninstalling

1. Quit audio applications.
2. Stop and remove the background service:

   ```sh
   launchctl bootout gui/$(id -u)/se.studiopatch.runtime
   rm ~/Library/LaunchAgents/se.studiopatch.runtime.plist
   ```

3. Remove the driver and broker:

   ```sh
   sudo bash Scripts/uninstall-driver.sh
   ```

4. Restart the Mac.

Your configuration and presets in `~/Library/Application Support/StudioPatch/` and driver backups in `/Library/Audio/StudioPatch Backups/` are kept. Delete them manually if you want a clean slate.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Panel says the StudioPatch device is unavailable | The driver is not loaded. Did you restart after installing? Check that `/Library/Audio/Plug-Ins/HAL/StudioPatch.driver` exists, then look for errors in the logs (see below). `Dist/patch-inspect` prints what Core Audio currently sees. |
| `install-driver.sh` asks you to install the transport first | The broker is missing or does not match the build. Run `sudo bash Scripts/install-transport.sh`. |
| "The background engine is not responding" | Check `launchctl print gui/$(id -u)/se.studiopatch.runtime`. Make sure the plist points to an existing `Dist/StudioPatch.app` (the clone has not moved). |
| Service runs but cannot connect to the driver | The broker probably holds an old signing requirement. Reinstall the broker, then restart the service. |
| Microphone prompt keeps appearing | The app and service must be signed with the same certificate. Rebuild with one identity and reinstall the service. |
| No notifications | Allow notifications for StudioPatch in System Settings → Notifications, and check Focus settings. |
| Build fails at `codesign` | The identity is wrong or its private key is not in your Keychain. See step 1. |
| Swift build fails inside a sandboxed tool or AI agent | SwiftUI macros and Keychain access need an unsandboxed shell. Run the build in a normal Terminal. |
| StudioPatch interface unavailable, "Audio interfaces unavailable" | A selected interface is disconnected, so the preset device has been removed from Core Audio. Reconnect every selected interface or remove missing ones from the configuration. |

The panel's status line and `~/Library/Application Support/StudioPatch/runtime-status.json` are the main diagnostics. For system logs from the service and the driver:

```sh
log show --last 10m --predicate 'process == "StudioPatchService" OR eventMessage CONTAINS "StudioPatch"'
```
