# Changelog

All notable changes to MacGuard. Newest first.

## 0.4
- **Security > Crypto miner check**: seven read-only checks and one verdict (Clear / Possible / Likely):
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
