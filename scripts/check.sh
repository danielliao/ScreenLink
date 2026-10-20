#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run ScreenLinkChecks
bash scripts/check-typing.sh
swift build --product ScreenLink
plutil -lint Resources/Info.plist
