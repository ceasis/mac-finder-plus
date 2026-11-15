#!/usr/bin/env bash
set -euo pipefail

# Runs as an Xcode build phase before signing, for both Xcode and shell builds.
# Only the built app is stamped; the checked-in Info.plist stays untouched.
ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESOURCES_DIR="${TARGET_BUILD_DIR:?Missing TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing UNLOCALIZED_RESOURCES_FOLDER_PATH}"
METADATA_FILE="$RESOURCES_DIR/WorkbenchBuildMetadata.plist"
BUILT_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
BUILD_IDENTIFIER="${WORKBENCH_BUILD_NUMBER:-$(/bin/date -u '+%Y%m%d%H%M%S')}"
REVISION="unknown"
HAS_UNCOMMITTED_CHANGES=false

if /usr/bin/git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REVISION="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
  if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    HAS_UNCOMMITTED_CHANGES=true
  fi
fi

mkdir -p "$RESOURCES_DIR"
/usr/bin/plutil -create xml1 "$METADATA_FILE"
/usr/bin/plutil -insert identifier -string "$BUILD_IDENTIFIER" "$METADATA_FILE"
/usr/bin/plutil -insert builtAt -string "$BUILT_AT" "$METADATA_FILE"
/usr/bin/plutil -insert revision -string "$REVISION" "$METADATA_FILE"
/usr/bin/plutil -insert hasUncommittedChanges -bool "$HAS_UNCOMMITTED_CHANGES" "$METADATA_FILE"
/usr/bin/plutil -insert configuration -string "${CONFIGURATION:-Unknown}" "$METADATA_FILE"

echo "Workbench build $BUILD_IDENTIFIER · $REVISION · $BUILT_AT"
