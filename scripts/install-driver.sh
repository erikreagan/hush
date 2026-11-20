#!/bin/bash
# Installs the Hush virtual mic driver. Needs admin; briefly interrupts all Mac audio.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/driver/Hush.driver ] || scripts/build-driver.sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver
sudo cp -R build/driver/Hush.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
echo "Installed. 'Hush Mic' should now appear in System Settings > Sound > Input."
