#!/usr/bin/env bash
set -euo pipefail

export COPYFILE_DISABLE=1

APP_NAME="Workbench"
PROJECT_NAME="MacFinderPlus.xcodeproj"
SCHEME="Workbench"
CONFIGURATION="Release"
BUNDLE_ID="com.qnsub.workbench.app"

ALLOW_ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --allow-adhoc)
      ALLOW_ADHOC=1
      ;;
    *)
      echo "usage: $0 [--allow-adhoc]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
DIST_DIR="$ROOT_DIR/build/gumroad"
STAGE_PARENT="$DIST_DIR/stage"
PACKAGE_ROOT="$STAGE_PARENT/$APP_NAME"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
ENTITLEMENTS="$ROOT_DIR/Workbench.entitlements"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Info.plist")"
ARCHIVE_BASENAME="$APP_NAME-$VERSION+$BUILD_NUMBER-macOS"
NOTARY_ZIP="$DIST_DIR/$ARCHIVE_BASENAME-notary.zip"
FINAL_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
CHECKSUM_FILE="$FINAL_ZIP.sha256"

SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$STAGE_PARENT" "$NOTARY_ZIP" "$FINAL_ZIP" "$CHECKSUM_FILE"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  ONLY_ACTIVE_ARCH=NO \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing with: $SIGNING_IDENTITY"
  if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "Warning: direct-download apps should use a Developer ID Application certificate." >&2
  fi
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
else
  if [[ "$ALLOW_ADHOC" != "1" ]]; then
    cat >&2 <<EOF
No Developer ID signing identity was provided.

Public Gumroad builds should be signed and notarized. Re-run like:

DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \\
NOTARY_KEYCHAIN_PROFILE="workbench-notary" \\
$0

For internal testing only, use:

$0 --allow-adhoc
EOF
    exit 1
  fi

  echo "Signing ad-hoc for internal testing only."
  codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - \
    "$APP_BUNDLE"
fi

codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"

  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
  elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
    xcrun stapler staple "$APP_BUNDLE"
  else
    echo "Notarization skipped: set NOTARY_KEYCHAIN_PROFILE or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD."
  fi
fi

mkdir -p "$PACKAGE_ROOT"
cp -R "$APP_BUNDLE" "$PACKAGE_ROOT/"
cp "$ROOT_DIR/release/gumroad/INSTALL.txt" "$PACKAGE_ROOT/Read Me First.txt"
cp "$ROOT_DIR/release/gumroad/PRIVACY_POLICY.md" "$PACKAGE_ROOT/Privacy Policy.md"
cp "$ROOT_DIR/release/gumroad/SUPPORT.md" "$PACKAGE_ROOT/Support.md"
cp "$ROOT_DIR/release/gumroad/VERSION_NOTES.md" "$PACKAGE_ROOT/Version Notes.md"
xattr -cr "$PACKAGE_ROOT"

(
  cd "$STAGE_PARENT"
  zip -q -r -X "$FINAL_ZIP" "$APP_NAME"
)
shasum -a 256 "$FINAL_ZIP" > "$CHECKSUM_FILE"

echo
echo "Created: $FINAL_ZIP"
echo "SHA-256: $(awk '{print $1}' "$CHECKSUM_FILE")"

if [[ "$ALLOW_ADHOC" == "1" && -z "$SIGNING_IDENTITY" ]]; then
  echo
  echo "Internal test package only. Do not upload this ad-hoc build to Gumroad."
fi
