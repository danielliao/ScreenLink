#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/ScreenLink/PasswordTyping.swift Tests/ScreenLinkTypingChecks/main.swift -o .build/ScreenLinkTypingChecks
.build/ScreenLinkTypingChecks
