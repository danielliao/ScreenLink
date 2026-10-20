#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Requires an interactive macOS desktop. Uses only temporary fixture windows;
# never loads ScreenLink settings, credentials, network or lock/unlock actions.
mkdir -p .build
swiftc Sources/ScreenLink/NativePrompt.swift Tests/ScreenLinkPromptChecks/main.swift -o .build/ScreenLinkPromptChecks
.build/ScreenLinkPromptChecks
