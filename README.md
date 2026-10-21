# MacGuard

Lightweight native monitor for Apple Silicon (M1–M4): CPU, RAM, temperature, top processes (right-click to quit), startup items, miner indicators, storage (empty caches/Trash, logs), alerts and settings.
Swift + SwiftUI, built with Command Line Tools only (no Xcode).

## Build

```bash
xcode-select --install        # once, if `swift --version` fails
cd MacGuard
chmod +x build.sh && ./build.sh
./build/MacGuard.app/Contents/MacOS/MacGuard --selftest   # check numbers vs Activity Monitor
open build/MacGuard.app
```

First launch of an ad-hoc signed app: right-click > Open if Gatekeeper complains.

## How the data is read (and why)

| Metric | Source | Notes |
|---|---|---|
| CPU % | Mach `host_processor_info` tick deltas | Same source as Activity Monitor |
| Memory | `host_statistics64` | Used = App + Wired + Compressed (Activity Monitor definition); pressure from `kern.memorystatus_vm_pressure_level` |
| Per-process CPU/RAM | `proc_pid_rusage` | CPU ticks converted with `mach_timebase_info` (125/3 on Apple Silicon). Root/other-user processes fall back to `ps` and are labelled "Estimated" |
| Temperature | IOHIDEventSystem (private, loaded with dlsym) | Same route as macmon/Stats. Falls back to public `ProcessInfo.thermalState`. No separate motherboard sensor exists on Apple Silicon |
| Startup items | LaunchAgents/LaunchDaemons plists + in-process code-signature check | `sfltool dumpbtm` needs root, so not used |
| Miner indicators | Names/arguments, sustained CPU, odd paths, unsigned binary, pool ports (`lsof`) | Signals, not verdicts |
| Storage | `URLResourceValues` | Read-only; never deletes |

## Weight / safety choices
- Samples every 2 s with the window visible, 5 s when hidden; no animations.
- Private sensor API is resolved at runtime; if missing, the app shows "n/a" instead of crashing.
- Heavy work (startup scan, deep scan, `lsof`) runs only on demand or when a process is already busy.

## Known limits
- Cannot see inside root processes beyond `ps` estimates, and cannot block anything (needs Apple's Endpoint Security entitlement).
- Temperature sensor names differ per chip; `--selftest` and the Overview "All temperature sensors" list show what your Mac exposes.
- Trash/Library scans may need Full Disk Access to report full sizes.
- Complements, not replaces, Objective-See's KnockKnock / BlockBlock / LuLu.

## New in 0.2
- Steep-style UI (warm paper, serif headings, pill buttons); risk colors High / Mid / Low always come with a text label.
- Right-click a process (Processes or Security tab) to Quit (SIGTERM) or Force Quit (SIGKILL). Core system processes are protected; root-owned ones can't be killed without admin rights.
- Storage: Empty Caches (contents of ~/Library/Caches) and Empty Trash (through Finder; macOS asks once to allow control of Finder). Both ask for confirmation.
- Every storage check, cache wipe and Trash wipe is appended to `MacGuard-storage.log` in a folder you choose (Settings > Storage logs; default ~/Library/Logs/MacGuard).
- Settings: theme (System/Light/Dark), temperature sensor toggle, alerts (overheating contributors, high-risk processes), keep running in background, start at login.
- Icon: `tools/make_icon.py` regenerates `Resources/AppIcon.iconset`; `build.sh` turns it into the .icns.

## New in 0.3
- **History** tab: CPU, CPU temperature and memory graphs for the last 15 minutes or hour (one reading every 10 s, kept in memory).
- **Storage > Large files**: scan your home folder (or any folder/drive) for the biggest folders and files, show in Finder, or move to Trash (recoverable). Each scan is written to the storage log.
- `./run.sh` quits, rebuilds and relaunches. `tools/setup-signing.sh` (run once) creates a stable local signing identity; `build.sh` uses it automatically. `tools/ship.sh "message"` commits and pushes.

## New in 0.4
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

## Contributing

Contributions and ideas are welcome. I'm open to listening to anyone who wants to help.

- **Want a feature?** [Open an issue](https://github.com/aminerochdi1/MacGuard/issues/new) with the label `wanted feature`. Say what you need and why, and include your Mac model and macOS version if it's hardware-related.
- **Found a bug or a problem?** [Open an issue](https://github.com/aminerochdi1/MacGuard/issues/new) with the label `bug`. Include the steps to reproduce, what you expected, and the output of `./build/MacGuard.app/Contents/MacOS/MacGuard --selftest` if numbers look wrong.
- **Installation or build problem?** Open an issue with the label `installation`. Include your Mac model, macOS version, the output of `swift --version`, and the full terminal output of `./build.sh`.
- **Want to code it?** Fork the repo, create a branch, make one focused change, and open a pull request describing what changed and how you tested it.

Ground rules:
- Keep it lightweight: no heavy dependencies, no animations, no background work that isn't needed.
- Read-only by default; anything that deletes or kills must ask for confirmation first.
- Keep it crash-safe: private APIs are resolved at runtime and fail to "n/a".
- Update this README with every user-facing feature.
- Build with Command Line Tools only (no Xcode project required).

Good first ideas are listed under the `wanted feature` label in Issues.

## Speed: storage checks
Storage checks are close to instant in everyday use, noticeably faster than the native macOS storage screen, which can take a long time to calculate and index folders. In hands-on testing on an M2 MacBook (not a formal benchmark) the disk-free figure and the cleanup scan came back almost immediately.

Why it is fast:
- Free space is read straight from the volume (`URLResourceValues`), with no indexing step.
- The cleanup scan only measures a few known folders (Caches, Logs, Trash, Xcode DerivedData) and the 8 biggest cache folders.
- Work runs in the background, so the window never freezes, and the Large files scan can be stopped at any time.

Large files scans walk every file in the chosen folder, so a huge folder or drive still takes longer than the cleanup scan.
