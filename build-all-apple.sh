#!/usr/bin/env bash
set -euo pipefail

# Unified Build Script for Voltix (iOS & tvOS)
# Usage:
#   ./build-all-apple.sh          -> Builds both iOS and tvOS
#   ./build-all-apple.sh ios      -> Builds iOS only
#   ./build-all-apple.sh tvos     -> Builds tvOS only

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Voltix"
TARGET="${1:-all}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: Apple builds require macOS." >&2
  exit 1
fi

resolve_flutter() {
  if [ -n "${FLUTTER_BIN:-}" ] && [ -x "$FLUTTER_BIN" ]; then
    printf '%s\n' "$FLUTTER_BIN"
    return 0
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi
  local candidates=(
    "$HOME/flutter/bin/flutter"
    "$HOME/Documents/flutter/bin/flutter"
    "$HOME/snap/flutter/common/flutter/bin/flutter"
  )
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "Error: Flutter executable not found on PATH." >&2
  exit 1
}

FLUTTER="$(resolve_flutter)"
APP_VERSION=$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version:[[:space:]]*//' | cut -d'+' -f1 | tr -d '[:space:]')

echo "============================================================"
echo " Voltix Apple Builder (v${APP_VERSION})"
echo " Target: ${TARGET}"
echo "============================================================"

build_ios() {
  echo ""
  echo ">>> [1/2] Building iOS Release IPA..."
  cd "$REPO_ROOT"
  "$FLUTTER" pub get
  cd "$REPO_ROOT/ios"
  pod install
  cd "$REPO_ROOT"

  rm -rf "$REPO_ROOT/build/ios"
  "$FLUTTER" build ipa --release --no-codesign --dart-define=DISTRIBUTION_CHANNEL=ios_unsigned

  local archive_dir="$REPO_ROOT/build/ios/archive"
  local app_path="$(find "$archive_dir" -type d -path '*/Products/Applications/*.app' | head -n 1)"
  if [ -z "$app_path" ]; then
    echo "Error: iOS .app not found in archive" >&2
    return 1
  fi

  local tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/Payload"
  cp -R "$app_path" "$tmp_dir/Payload/"
  local out_ipa="$REPO_ROOT/${APP_NAME}_iOS_v${APP_VERSION}_unsigned.ipa"
  (
    cd "$tmp_dir"
    zip -qry "$out_ipa" Payload
  )
  rm -rf "$tmp_dir"

  echo "✅ iOS Build Complete: $out_ipa"
}

build_tvos() {
  echo ""
  echo ">>> [2/2] Building tvOS (Apple TV) Release IPA..."
  cd "$REPO_ROOT"
  "$FLUTTER" pub get

  echo "Bundling assets for tvOS..."
  mkdir -p "$REPO_ROOT/tvos/Flutter/flutter_assets"
  "$FLUTTER" build bundle --release --target-platform=ios --asset-dir="$REPO_ROOT/tvos/Flutter/flutter_assets"

  cd "$REPO_ROOT/tvos"
  pod install
  cd "$REPO_ROOT"

  local tvos_archive="$REPO_ROOT/build/tvos/archive/Runner.xcarchive"
  rm -rf "$REPO_ROOT/build/tvos"
  mkdir -p "$REPO_ROOT/build/tvos/archive"

  xcodebuild -workspace "$REPO_ROOT/tvos/Runner.xcworkspace" \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=tvOS' \
    archive -archivePath "$tvos_archive" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

  local tvos_app="$(find "$REPO_ROOT/build/tvos/archive" -type d -path '*/Products/Applications/*.app' | head -n 1)"
  if [ -z "$tvos_app" ]; then
    echo "Error: tvOS .app not found in archive" >&2
    return 1
  fi

  local tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/Payload"
  cp -R "$tvos_app" "$tmp_dir/Payload/"
  local out_tvos_ipa="$REPO_ROOT/${APP_NAME}_tvOS_v${APP_VERSION}_unsigned.ipa"
  (
    cd "$tmp_dir"
    zip -qry "$out_tvos_ipa" Payload
  )
  rm -rf "$tmp_dir"

  echo "✅ tvOS Build Complete: $out_tvos_ipa"
}

case "$TARGET" in
  ios)
    build_ios
    ;;
  tvos)
    build_tvos
    ;;
  all)
    build_ios
    build_tvos
    ;;
  *)
    echo "Unknown target: $TARGET. Use 'ios', 'tvos', or 'all'."
    exit 1
    ;;
esac

echo ""
echo "============================================================"
echo "🎉 Build Process Completed!"
ls -lh "$REPO_ROOT"/*.ipa
echo "============================================================"
