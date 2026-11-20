#!/bin/bash
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver
sudo killall coreaudiod
echo "Removed Hush driver."
