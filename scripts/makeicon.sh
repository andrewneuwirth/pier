#!/bin/zsh
# Renders Resources/UsageRings.icns: the Mac Tools family plate (Kit/tools/icon.swift) in Usage
# Rings' accent, with Resources/Glyph.svg drawn on it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift ../Kit/tools/icon.swift b98fdd Resources/Glyph.svg Resources/UsageRings.icns
