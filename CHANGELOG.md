# Changelog

All notable changes to MacGuard. Newest first.

## 0.8
- **Pause and resume any process**: Pause (freezes it without losing its work) and Resume buttons on Security suspects, the Processes tab, and the apps listed on the Battery tab, next to Quit. Paused apps are resumed automatically when MacGuard quits.
- **Disable startup items and browser extensions**: the Startup tab gets a Disable button for your own LaunchAgents and Chromium extensions (Chrome, Brave, Edge, Vivaldi, Opera, Arc). Files are moved aside, never deleted, and can be switched back on from "Disabled by MacGuard".
- **Colored CPU and memory**: the Overview CPU and Memory (RAM) cards show a percentage colored green (low), yellow (medium) or red (high), always with the word. New "Top memory users now" list.

## 0.7
- **Homebrew**: `brew install --cask aminerochdi1/macguard/macguard`. A cask template and `tools/release.sh` generate the cask for each release.
- **Network tab, live and per process**: each process using the network gets its own row (with PID), updated every couple of seconds. Apps stay listed for two minutes after they go quiet (shown as idle), and a "This session" column adds up what each used since you opened the tab. Sort by busiest now or most this session.
- **Quit from the Network tab**: right-click a row for Quit, Force Quit, Show in Finder or Copy PID, or select a row and use the buttons. Core system processes are protected.
- **About MacGuard**: click the MacGuard title (or MacGuard > About MacGuard in the menu bar) to see who made it, with links to GitHub, issues and releases.
- **Check for updates**: compares your version with the latest GitHub release and links to the download. It only contacts GitHub when you press the button.

## 0.6
- **New since last scan**: startup items remember when they were first seen. Anything added since your last scans is marked New for 7 days, shown in a banner on the Startup tab, and notifies you. MacGuard checks every 15 minutes (Settings > Alerts > New startup items). The very first scan only records a baseline.
- **Startup tab sections**: Launch items, Shell & cron (your shell startup files, `/etc` shell files when something looks wrong, and cron jobs) and Browser extensions (Chrome, Brave, Edge, Vivaldi, Opera, Arc, Firefox).
- **Library injection**: flags `DYLD_INSERT_LIBRARIES` in LaunchAgent/Daemon plists and in installed apps (`LSEnvironment`).
- **Notarization**: code signatures now show "Notarized" for Developer ID apps Apple has notarized.
- **Crypto miner check** now has eight checks: the new one looks for miner names in browser extensions.
- Inspired by Objective-See's KnockKnock (no code copied); see the README acknowledgements.

## 0.5
- **Trusted apps (allowlist)**: a Trust button on flagged processes and startup items (also in the right-click menu). Trusted programs are no longer flagged, unless their name or command line matches a known crypto miner. Review or remove them in Settings > Trusted apps.
- **Battery colours**: charge is red when low (20% or less), yellow when medium (21 to 50%) and green when high (above 50%), with the word Low / Medium / High next to it. Applies to the Battery tab, Overview and notch popover.
- **Release builds**: `tools/release.sh` builds, zips and checksums the app into `dist/`; `tools/release.sh --publish` also creates the GitHub release with notes from this changelog. `tools/bump-version.sh 0.6.0` sets the version.
- **Battery** tab: charge, charging state, time left, battery power in watts, maximum capacity (health) with cycle count, battery temperature, and the apps most likely draining it (estimated from CPU use). Also on the Overview. Desktop Macs show "No battery".
- **Network** tab: download and upload for the whole Mac, plus per-app rates (from macOS `nettop`, sampled only while the tab is open).
- **Notch popover**: rest the mouse next to the notch and a small black panel grows out of it with CPU, temperature, memory, battery, network and the top 3 apps. Sized from the real notch and display resolution, so it fits 13/14/15/16 inch MacBooks. Fades instead of growing when Reduce Motion is on. Toggle in Settings > Notch popover. Only on Macs with a notch.
- Window is a little wider to fit the two new tabs.

## 0.4
- **Fewer false alarms**: a validly code-signed app (Chrome, VS Code helpers, etc.) is no longer flagged only because it runs from a temporary folder such as `/private/var/folders`. Unsigned binaries there, or any app with a real miner signal (name, command line, sustained CPU, pool connection), are still flagged.
- **Security > Crypto miner check**: seven read-only checks (eight since 0.6) and one verdict (Clear / Possible / Likely):
  1. running processes (miner names and command-line arguments, e.g. xmrig, stratum+tcp, --donate-level)
  2. sustained high CPU from non-Apple apps with no window
  3. connections to common mining-pool ports (your own processes)
  4. startup items (LaunchAgents/LaunchDaemons) with miner indicators or odd locations
  5. cron and shell startup files (.zshrc, .zprofile, .bashrc...) for miner commands or `curl | sh` / base64 loaders
  6. miner-like files and pool config files in /tmp, Application Support, ~/.config, LaunchAgents
  7. browser helper processes pinned at high CPU (in-browser mining)
- Runs on demand and automatically every 30 minutes (Settings > Automatic crypto miner check); a notification appears if something is found, at most once every 6 hours.
- **Memory graph**: the vertical axis now zooms to your actual range and the line is coloured by memory pressure (Normal / Warning / Critical), the number that really shows memory trouble. A flat ~80% with Normal pressure is healthy, same as Activity Monitor.
- Limits: this is signal-based detection, not antivirus. A miner that hides under a system name, runs as root, or throttles itself can be missed. Use KnockKnock / BlockBlock alongside.

## 0.3
- **History** tab: CPU, CPU temperature and memory graphs for the last 15 minutes or hour (one reading every 10 s, kept in memory).
- **Storage > Large files**: scan your home folder (or any folder/drive) for the biggest folders and files, show in Finder, or move to Trash (recoverable). Each scan is written to the storage log.
- `./run.sh` quits, rebuilds and relaunches. `tools/setup-signing.sh` (run once) creates a stable local signing identity; `build.sh` uses it automatically. `tools/ship.sh "message"` commits and pushes.

## 0.2
- Steep-style UI (warm paper, serif headings, pill buttons); risk colors High / Mid / Low always come with a text label.
- Right-click a process (Processes or Security tab) to Quit (SIGTERM) or Force Quit (SIGKILL). Core system processes are protected; root-owned ones can't be killed without admin rights.
- Storage: Empty Caches (contents of ~/Library/Caches) and Empty Trash (through Finder; macOS asks once to allow control of Finder). Both ask for confirmation.
- Every storage check, cache wipe and Trash wipe is appended to `MacGuard-storage.log` in a folder you choose (Settings > Storage logs; default ~/Library/Logs/MacGuard).
- Settings: theme (System/Light/Dark), temperature sensor toggle, alerts (overheating contributors, high-risk processes), keep running in background, start at login.
- Icon: `tools/make_icon.py` regenerates `Resources/AppIcon.iconset`; `build.sh` turns it into the .icns.

## 0.1
- First release: CPU, memory, temperature, top processes, startup items, miner indicators, storage overview.
