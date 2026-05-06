#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT_DIR"

xcodebuild \
  -project iOSSimulatorManager.xcodeproj \
  -scheme iOSSimulatorManager \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/build" \
  build

open -n "$ROOT_DIR/build/iOS模拟器管理.app"
