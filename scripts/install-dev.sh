#!/usr/bin/env bash
# install-dev.sh — build 法墨输入法 (Famo) and install it to the user's
# ~/Library/Input Methods (no sudo). Local DEV install: ad-hoc codesign only.
#
# NOTE: Build product path for this Famo app is
#   build/Build/Products/{Debug,Release}/Famo.app
# (Makefile uses -derivedDataPath build), NOT build/Release/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"          # Debug (default, fast) or Release
ARCHS="${ARCHS:-arm64}"
DEPLOY="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

APP_NAME="Famo.app"
PRODUCT_EXECUTABLE="Famo"
INSTALL_DIR="$HOME/Library/Input Methods"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"
SYSTEM_APP="/Library/Input Methods/$APP_NAME"

echo "Project root: $ROOT"
echo "Config: $CONFIG  ARCHS: $ARCHS  Deployment: $DEPLOY"

if [[ -d "$SYSTEM_APP" && "$INSTALLED_APP" != "$SYSTEM_APP" && -z "${FAMO_ALLOW_USER_DUPLICATE:-}" ]]; then
  echo "ERROR: system-level Famo.app already exists: $SYSTEM_APP"
  echo "Installing another dev copy under $INSTALL_DIR would create duplicate Famo input sources."
  echo "Move the system-level Famo aside first, or set FAMO_ALLOW_USER_DUPLICATE=1 for a deliberate duplicate."
  exit 1
fi

echo "Building ($CONFIG)..."
if [[ -f Makefile ]]; then
  # 'make debug' / 'make release' both depend on the prebuilt librime/opencc/plum
  # deps from action-install.sh. Run action-install.sh first if deps are missing.
  if [[ "$CONFIG" == "Release" ]]; then
    make release ARCHS="$ARCHS" MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
  else
    make debug ARCHS="$ARCHS" MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
  fi
else
  xcodebuild \
    -project Owltype.xcodeproj \
    -scheme Owltype \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    ARCHS="$ARCHS" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOY" \
    build
fi

echo "Locating build product..."
CANDIDATES=(
  "$ROOT/build/Build/Products/$CONFIG/$APP_NAME"
  "$ROOT/build/Build/Products/Debug/$APP_NAME"
  "$ROOT/build/Build/Products/Release/$APP_NAME"
  "$ROOT/build/Build/Products/$CONFIG/Famo.app"
)

BUILD_APP=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    BUILD_APP="$candidate"
    break
  fi
done

if [[ -z "$BUILD_APP" ]]; then
  echo "ERROR: cannot find built app. Looked in build/Build/Products/. Check Xcode output."
  exit 1
fi
echo "Using build product: $BUILD_APP"

mkdir -p "$INSTALL_DIR"

killall Famo 2>/dev/null || true
# Do NOT touch the user's Squirrel — it's a separate input method.

# Update IN PLACE (rsync into the existing bundle), NOT rm -rf + cp. Replacing the
# whole bundle deregisters Famo from the user's input-source list (it disappears from
# the input menu and they must re-add it). Syncing into the existing bundle keeps its
# identity / TIS registration intact across dev reinstalls.
if [[ -d "$INSTALLED_APP" ]]; then
  rsync -a --delete "$BUILD_APP"/ "$INSTALLED_APP"/
else
  cp -R "$BUILD_APP" "$INSTALLED_APP"
fi

# Leave a clear trace if the built app is missing the expected executable.
if [[ ! -x "$INSTALLED_APP/Contents/MacOS/$PRODUCT_EXECUTABLE" ]]; then
  echo "WARN: '$PRODUCT_EXECUTABLE' executable not found in installed bundle."
  echo "Available executables:"
  ls -la "$INSTALLED_APP/Contents/MacOS" || true
  found="$(find "$INSTALLED_APP/Contents/MacOS" -type f -perm -111 ! -name '*.dylib' | head -n 1)"
  PRODUCT_EXECUTABLE="$(basename "$found")"
  echo "Fallback executable: $PRODUCT_EXECUTABLE"
fi

echo "Ad-hoc signing installed app (dev only)..."
codesign --force --deep --sign - "$INSTALLED_APP" || {
  echo "WARN: ad-hoc codesign failed. Continue only for local debug if macOS allows it."
}

EXE="$INSTALLED_APP/Contents/MacOS/$PRODUCT_EXECUTABLE"

if [[ -x "$EXE" ]]; then
  echo "Registering input source..."
  "$EXE" --register-input-source || true
  "$EXE" --enable-input-source || true
  "$EXE" --select-input-source im.famo.inputmethod.Famo.Hans || true
  echo "Launching Famo input method app..."
  open -g "$INSTALLED_APP" || true
  # A pristine Aqua account can expose the registered modes only after LaunchServices has
  # started the input-method host once.  Retry through the public TIS APIs after that first
  # launch; do not rewrite AppleEnabledInputSources or other system preferences.
  sleep 3
  "$EXE" --activate-once || true
  "$EXE" --enable-input-source || true
  "$EXE" --select-input-source im.famo.inputmethod.Famo.Hans || true
else
  echo "ERROR: installed executable is not runnable: $EXE"
  exit 1
fi

echo
echo "Installed to: $INSTALLED_APP"
echo "Open System Settings -> Keyboard -> Text Input / Input Sources and add/select 法墨输入法."
echo "If it appears but cannot type, remove/add 法墨输入法 once in System Settings."
echo
echo "NOT EXECUTED automatically: System Settings selection, host-app typing, logout/reboot."
echo "These must be verified by hand on the real machine."
