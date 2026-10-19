#!/usr/bin/env bash
# install-dev.sh — build 猫头鹰输入法 (Owltype) and install it to the user's
# ~/Library/Input Methods (no sudo). The installed copy is signed with a stable
# certificate identity (scripts/stable-sign-identity.sh), never ad hoc: Keychain grants
# follow the designated requirement, and an ad hoc cdhash changes with every build.
#
# NOTE: Build product path for this Owltype app is
#   build/Build/Products/{Debug,Release}/Owltype.app
# (Makefile uses -derivedDataPath build), NOT build/Release/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"          # Debug (default, fast) or Release
ARCHS="${ARCHS:-arm64}"
DEPLOY="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

APP_NAME="Owltype.app"
PRODUCT_EXECUTABLE="Owltype"
INSTALL_DIR="$HOME/Library/Input Methods"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"
SYSTEM_APP="/Library/Input Methods/$APP_NAME"

echo "Project root: $ROOT"
echo "Config: $CONFIG  ARCHS: $ARCHS  Deployment: $DEPLOY"

if [[ -d "$SYSTEM_APP" && "$INSTALLED_APP" != "$SYSTEM_APP" && -z "${OWL_ALLOW_USER_DUPLICATE:-}" ]]; then
  echo "ERROR: system-level Owltype.app already exists: $SYSTEM_APP"
  echo "Installing another dev copy under $INSTALL_DIR would create duplicate Owltype input sources."
  echo "Move the system-level Owltype aside first, or set OWL_ALLOW_USER_DUPLICATE=1 for a deliberate duplicate."
  exit 1
fi

# Resolve the identity before building so a machine without one fails fast.
SIGN_IDENTITY="$(bash "$ROOT/scripts/stable-sign-identity.sh")"
echo "Signing identity: $SIGN_IDENTITY"

# Prints the designated requirement of a bundle, or nothing when it is unsigned.
designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -nE 's/^(# )?designated => //p' | head -1
}

# Ad hoc requirements are the per-build cdhash ("# designated => cdhash H\"...\""):
# Keychain would ask for the login password after every install, and leftover ad hoc
# copies shadow the notarized input method in LaunchServices.
require_stable_signature() {
  local candidate="$1" installed="$2" requirement current
  requirement="$(designated_requirement "$candidate")"
  if [[ -z "$requirement" || "$requirement" == cdhash* ]]; then
    echo "ERROR: $candidate is ad hoc signed (designated => ${requirement:-none}); refusing to install it."
    echo "Install development builds with: bash scripts/install-dev.sh"
    echo "It signs with a stable identity; OWL_SIGN_IDENTITY selects one from: security find-identity -v -p codesigning"
    exit 1
  fi
  if [[ -d "$installed" ]]; then
    current="$(designated_requirement "$installed")"
    if [[ -n "$current" && "$current" != cdhash* && "$current" != "$requirement" ]]; then
      echo "ERROR: $installed is signed by a different identity; replacing it would drop its Keychain grants."
      echo "Installed: designated => $current"
      echo "Candidate: designated => $requirement"
      echo "Set OWL_SIGN_IDENTITY to the installed identity, or remove $installed deliberately first."
      exit 1
    fi
  fi
}

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
  "$ROOT/build/Build/Products/$CONFIG/Owltype.app"
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

echo "Signing build product with $SIGN_IDENTITY..."
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT/resources/Owltype.entitlements" "$BUILD_APP"
require_stable_signature "$BUILD_APP" "$INSTALLED_APP"

mkdir -p "$INSTALL_DIR"

killall Owltype 2>/dev/null || true
# Do NOT touch the user's Squirrel — it's a separate input method.

# Update IN PLACE (rsync into the existing bundle), NOT rm -rf + cp. Replacing the
# whole bundle deregisters Owltype from the user's input-source list (it disappears from
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

codesign --verify --deep --strict "$INSTALLED_APP"

EXE="$INSTALLED_APP/Contents/MacOS/$PRODUCT_EXECUTABLE"

if [[ -x "$EXE" ]]; then
  echo "Registering input source..."
  "$EXE" --register-input-source || true
  "$EXE" --enable-input-source || true
  "$EXE" --select-input-source im.owltype.inputmethod.Owltype.Hans || true
  echo "Launching Owltype input method app..."
  open -g "$INSTALLED_APP" || true
  # A pristine Aqua account can expose the registered modes only after LaunchServices has
  # started the input-method host once.  Retry through the public TIS APIs after that first
  # launch; do not rewrite AppleEnabledInputSources or other system preferences.
  sleep 3
  "$EXE" --activate-once || true
  "$EXE" --enable-input-source || true
  "$EXE" --select-input-source im.owltype.inputmethod.Owltype.Hans || true
else
  echo "ERROR: installed executable is not runnable: $EXE"
  exit 1
fi

echo
echo "Installed to: $INSTALLED_APP"
echo "Open System Settings -> Keyboard -> Text Input / Input Sources and add/select 猫头鹰输入法."
echo "If it appears but cannot type, remove/add 猫头鹰输入法 once in System Settings."
echo
echo "NOT EXECUTED automatically: System Settings selection, host-app typing, logout/reboot."
echo "These must be verified by hand on the real machine."
