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
