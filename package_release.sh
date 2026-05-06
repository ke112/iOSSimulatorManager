#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$ROOT_DIR/build/iOS模拟器管理.app"
ZIP_PATH="$ROOT_DIR/build/iOS模拟器管理.zip"
INSTALL_APP_PATH="/Applications/iOS模拟器管理.app"
PACKAGE_DIR="$(mktemp -d /tmp/iOSSimulatorManagerPackage.XXXXXX)"

cleanup() {
  rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

xcodebuild \
  -project iOSSimulatorManager.xcodeproj \
  -scheme iOSSimulatorManager \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PACKAGE_DIR" \
  build

mkdir -p "$ROOT_DIR/build"
rm -rf "$APP_PATH" "$ZIP_PATH"
ditto "$PACKAGE_DIR/iOS模拟器管理.app" "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -w "/Applications" && ( ! -e "$INSTALL_APP_PATH" || -w "$INSTALL_APP_PATH" ) ]]; then
  rm -rf "$INSTALL_APP_PATH"
  ditto "$APP_PATH" "$INSTALL_APP_PATH"
else
  sudo rm -rf "$INSTALL_APP_PATH"
  sudo ditto "$APP_PATH" "$INSTALL_APP_PATH"
fi

echo "Packaged: $APP_PATH"
echo "Zip: $ZIP_PATH"
echo "Installed: $INSTALL_APP_PATH"
