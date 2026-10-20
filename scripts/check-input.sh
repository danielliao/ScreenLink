#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Tests/ScreenLinkInputChecks/main.swift -o .build/ScreenLinkInputChecks
.build/ScreenLinkInputChecks
