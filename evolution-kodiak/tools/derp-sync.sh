#!/bin/bash
set -euo pipefail
cd ~/derpfest
echo "=== DerpFest Repo Sync Started: $(date) ==="
echo "[1/2] Fetching repositories (-j4, optimized-fetch)..."
repo sync -c -n -j4 --no-tags --no-clone-bundle --optimized-fetch --retry-fetches=5
echo "[2/2] Checking out local worktrees (-j16)..."
repo sync -c -l -j16
echo "=== DerpFest Repo Sync Completed: $(date) ==="
