#!/usr/bin/env bash
set -euo pipefail

export COPYFILE_DISABLE=1

APP_NAME="Workbench"
PROJECT_NAME="MacFinderPlus.xcodeproj"
SCHEME="Workbench"
CONFIGURATION="Release"
BUNDLE_ID="com.qnsub.workbench.app"

ALLOW_ADHOC=0
CHANNEL=gumroad
PREPARE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --allow-adhoc)
      ALLOW_ADHOC=1
      ;;
    --qnsub)
      CHANNEL=qnsub
      ;;
    --prepare-qnsub)
      CHANNEL=qnsub
      PREPARE_ONLY=1
      ;;
    *)
      echo "usage: $0 [--allow-adhoc | --qnsub | --prepare-qnsub]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/resolve_developer_dir.sh"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
DIST_DIR="$ROOT_DIR/build/$CHANNEL"
STAGE_PARENT="$DIST_DIR/stage"
PACKAGE_ROOT="$STAGE_PARENT/$APP_NAME"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
ENTITLEMENTS="$ROOT_DIR/Workbench.entitlements"

SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

if [[ "$CHANNEL" == qnsub ]]; then
  if [[ "$ALLOW_ADHOC" == 1 || "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo 'A QnSub release requires Developer ID Application signing.' >&2
    exit 1
  fi
  if [[ "$PREPARE_ONLY" == 0 && -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    echo 'A distributable QnSub release requires a notarization keychain profile.' >&2
    exit 1
  fi
fi

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"

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

# The build phase stamps every build, including builds initiated in Xcode. Name
# the archive after that exact stamp instead of the source plist's legacy "1".
METADATA_PLIST="$APP_BUNDLE/Contents/Resources/WorkbenchBuildMetadata.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :identifier' "$METADATA_PLIST")"
ARCHIVE_BASENAME="$APP_NAME-$VERSION+$BUILD_NUMBER-macOS"
NOTARY_ZIP="$DIST_DIR/$ARCHIVE_BASENAME-notary.zip"
FINAL_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
CHECKSUM_FILE="$FINAL_ZIP.sha256"
rm -rf "$STAGE_PARENT" "$NOTARY_ZIP" "$FINAL_ZIP" "$CHECKSUM_FILE"

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

  if [[ "$PREPARE_ONLY" == 1 ]]; then
    echo "Prepared for notarization (not for distribution): $NOTARY_ZIP"
    exit 0
  fi

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
if [[ "$CHANNEL" == qnsub ]]; then
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute "$APP_BUNDLE"
  ditto "$APP_BUNDLE" "$PACKAGE_ROOT/$APP_NAME.app"
  cp "$ROOT_DIR/release/qnsub/INSTALL.txt" "$PACKAGE_ROOT/Read Me First.txt"
  ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT" "$FINAL_ZIP"
  shasum -a 256 "$FINAL_ZIP" > "$CHECKSUM_FILE"
  echo "Created: $FINAL_ZIP"
  exit 0
fi
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
