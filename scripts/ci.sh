#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/3] Linting..."
swiftlint lint --strict

echo "==> [2/3] Building app targets..."
xcodegen generate
xcodebuild build -scheme LemurCam -destination 'platform=macOS' -allowProvisioningUpdates -allowProvisioningDeviceRegistration

echo "==> [3/3] Running tests..."
xcodebuild test -scheme LemurCam -destination 'platform=macOS' -quiet

echo "==> All CI checks passed."
