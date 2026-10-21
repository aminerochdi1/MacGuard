#!/bin/bash
# Quit the running app, rebuild, relaunch.
cd "$(dirname "$0")"
pkill -x MacGuard 2>/dev/null || true
./build.sh && open build/MacGuard.app
