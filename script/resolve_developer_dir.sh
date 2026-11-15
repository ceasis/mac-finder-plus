#!/usr/bin/env bash

# Source this from build scripts. Configure only their subprocess environment;
# never change the machine-wide xcode-select setting.
workbench_resolve_developer_dir() {
  local selected_dir standard_dir application candidate existing duplicate
  local candidate_count=0
  local candidates=()

  selected_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -x "$selected_dir/usr/bin/xcodebuild" && -d "$selected_dir/Platforms/MacOSX.platform" ]]; then
    printf '%s\n' "$selected_dir"
    return 0
  fi

  standard_dir="/Applications/Xcode.app/Contents/Developer"
  if [[ -x "$standard_dir/usr/bin/xcodebuild" && -d "$standard_dir/Platforms/MacOSX.platform" ]]; then
    printf '%s\n' "$standard_dir"
    return 0
  fi

  for application in /Applications/Xcode*.app "${HOME:-}/Applications"/Xcode*.app; do
    candidate="$application/Contents/Developer"
    [[ -x "$candidate/usr/bin/xcodebuild" && -d "$candidate/Platforms/MacOSX.platform" ]] || continue
    candidate="$(cd "$candidate" && /bin/pwd -P)"
    duplicate=false
    for existing in "${candidates[@]:-}"; do
      if [[ "$existing" == "$candidate" ]]; then
        duplicate=true
        break
      fi
    done
    if [[ "$duplicate" == false ]]; then
      candidates[$candidate_count]="$candidate"
      candidate_count=$((candidate_count + 1))
    fi
  done

  if [[ "$candidate_count" == 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  if [[ "$candidate_count" == 0 ]]; then
    echo "A full Xcode installation is required. Install Xcode or set DEVELOPER_DIR to its Contents/Developer directory." >&2
  else
    echo "Multiple Xcode installations were found. Set DEVELOPER_DIR explicitly before building:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
  fi
  return 1
}

workbench_configure_developer_dir() {
  # An explicit selection always wins, even if it points outside common paths.
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then return 0; fi
  local resolved_dir
  resolved_dir="$(workbench_resolve_developer_dir)" || return 1
  export DEVELOPER_DIR="$resolved_dir"
}

workbench_configure_developer_dir
