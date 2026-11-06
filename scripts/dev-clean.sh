#!/usr/bin/env bash
set -euo pipefail

# Clean LemurCam development state so a freshly built system extension can be
# installed without macOS holding onto a stale copy.
#
# macOS can re-stage the camera extension on reboot from ANY app bundle that
# embeds it (/Applications, DerivedData, repo build/, archives, Downloads...).
# So a real reset must (1) tell macOS to uninstall the extension and (2) delete
# every on-disk copy of the app bundle and any staged extension. Copies inside
# Xcode archives (release builds, notarization submissions) are only deleted
# with --include-archives.
#
# systemextensionsctl uninstall/reset/developer are refused while System
# Integrity Protection is enabled. Disable SIP from Recovery ('csrutil disable')
# and reboot before relying on those steps.

APP_NAME="${LEMURCAM_APP_NAME:-LemurCam}"
APP_BUNDLE_ID="${LEMURCAM_APP_BUNDLE_ID:-cam.lemur.app}"
EXT_BUNDLE_ID="${LEMURCAM_EXT_BUNDLE_ID:-cam.lemur.app.extension}"
TEAM_ID="${LEMURCAM_TEAM_ID:-2KG9772KH6}"
APP_GROUP_ID="${LEMURCAM_APP_GROUP_ID:-${TEAM_ID}.${APP_BUNDLE_ID}}"
KEYCHAIN_SERVICE="${LEMURCAM_KEYCHAIN_SERVICE:-cam.lemur.app.credentials}"
DRIVER_BUNDLE_NAME="${LEMURCAM_DRIVER_BUNDLE_NAME:-LemurCamAudio.driver}"
HAL_PLUGINS_DIR="${LEMURCAM_HAL_PLUGINS_DIR:-/Library/Audio/Plug-Ins/HAL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SYSEXT_ROOT="/Library/SystemExtensions"
ARCHIVES_ROOT="${HOME}/Library/Developer/Xcode/Archives"

# Audio HAL driver install path. Must match LemurAudioHelper.halPluginsDirectory
# and driverBundleName; the driver is root-owned, so removal needs sudo.
INSTALLED_DRIVER_PATH="${HAL_PLUGINS_DIR}/${DRIVER_BUNDLE_NAME}"
# Staging directories the helper leaves in HAL_PLUGINS_DIR when an install or
# uninstall is interrupted. Must match DriverInstaller.stagingPrefix (one per
# request, plus a random suffix) and DriverInstaller.legacyStagingName (older
# helpers) in Shared/DriverInstall/DriverInstaller.swift.
DRIVER_STAGING_PREFIX=".LemurCamAudio.staging."
DRIVER_LEGACY_STAGING_NAME=".LemurCamAudio.driver.staging"

EXECUTE=0
ASSUME_YES=0
KEEP_APPS=0
INCLUDE_ARCHIVES=0
KEEP_DERIVED_DATA=0
KEEP_EXTENSION=0
KEEP_DRIVER=0
KEEP_USER_STATE=0
KEEP_KEYCHAIN=0
DEVELOPER_ON=0
GLOBAL_TCC_RESET=0
GLOBAL_SYSEXT_RESET=0

usage() {
  cat <<EOF
Usage: scripts/dev-clean.sh [options]

Fully reset LemurCam development state. Defaults to dry-run; nothing is changed
until you pass --execute.

By default --execute will:
  - stop running LemurCam app/extension processes
  - uninstall the extension via 'systemextensionsctl uninstall' (needs SIP off)
  - delete EVERY LemurCam.app bundle it can find (the main cause of reboot
    re-staging), plus any staged ${EXT_BUNDLE_ID} under ${SYSEXT_ROOT}.
    Copies inside Xcode archives are kept unless you pass --include-archives.
  - remove the installed audio driver (${DRIVER_BUNDLE_NAME}) and any staging
    copies the helper left in ${HAL_PLUGINS_DIR}, and restart coreaudiod so it
    drops the plug-in
  - reset Camera (TCC) authorization for the app and extension
  - remove app-group / container / defaults user state, including the saved
    camera list (~/Library/Application Support/${APP_NAME}/sources.json)
  - delete Keychain credentials (${KEYCHAIN_SERVICE})
  - delete DerivedData and repo build/ outputs

Without --yes, each of these steps asks before it runs; any answer other than
"y" stops the script there. Use the --keep-* options to skip a step instead.

Options:
  --execute              Actually run the commands. Without this, only prints them.
  --yes                  Do not prompt before destructive operations.
  --keep-apps            Do not delete LemurCam.app bundles.
  --include-archives     Also delete LemurCam.app copies inside Xcode archives
                         (${ARCHIVES_ROOT}
                         or any .xcarchive), such as release builds and
                         notarization submissions. Off by default.
  --keep-derived-data    Do not delete DerivedData / repo build outputs.
  --keep-extension       Do not run 'systemextensionsctl uninstall'.
  --keep-driver          Do not remove the installed audio driver.
  --keep-user-state      Do not delete defaults, containers, or Application
                         Support data (the saved camera list).
  --keep-keychain        Do not delete Keychain credentials.
  --developer-on         Enable system extension developer mode (eases reloading
                         locally-built extensions; needs SIP off).
  --global-tcc-reset     Reset Camera permission for ALL apps, not just LemurCam.
  --global-sysext-reset  Run 'systemextensionsctl reset' (nuclear: clears state
                         for ALL system extensions, e.g. VPN/endpoint security).
  -h, --help             Show this help.

Environment overrides:
  LEMURCAM_APP_NAME, LEMURCAM_APP_BUNDLE_ID, LEMURCAM_EXT_BUNDLE_ID,
  LEMURCAM_TEAM_ID, LEMURCAM_APP_GROUP_ID, LEMURCAM_KEYCHAIN_SERVICE,
  LEMURCAM_DRIVER_BUNDLE_NAME, LEMURCAM_HAL_PLUGINS_DIR

Typical dev reset (SIP already disabled):
  scripts/dev-clean.sh --execute --yes
  # then reboot, rebuild with a bumped CURRENT_PROJECT_VERSION, relaunch.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --yes) ASSUME_YES=1 ;;
    --keep-apps) KEEP_APPS=1 ;;
    --include-archives) INCLUDE_ARCHIVES=1 ;;
    --keep-derived-data) KEEP_DERIVED_DATA=1 ;;
    --keep-extension) KEEP_EXTENSION=1 ;;
    --keep-driver) KEEP_DRIVER=1 ;;
    --keep-user-state) KEEP_USER_STATE=1 ;;
    --keep-keychain) KEEP_KEYCHAIN=1 ;;
    --developer-on) DEVELOPER_ON=1 ;;
    --global-tcc-reset) GLOBAL_TCC_RESET=1 ;;
    --global-sysext-reset) GLOBAL_SYSEXT_RESET=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

quote_cmd() {
  printf '%q ' "$@"
  printf '\n'
}

# Run a command, or print it in dry-run mode.
run() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    "$@"
  else
    printf 'DRY-RUN: '
    quote_cmd "$@"
  fi
}

run_allow_fail() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    "$@" || true
  else
    printf 'DRY-RUN: '
    quote_cmd "$@"
  fi
}

# Like run_allow_fail but elevates with sudo.
sudo_run_allow_fail() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    sudo "$@" || true
  else
    printf 'DRY-RUN: '
    quote_cmd sudo "$@"
  fi
}

confirm() {
  local message="$1"
  if [[ "$EXECUTE" -ne 1 || "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi

  printf '%s [y/N] ' "$message"
  local reply=""
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted; this step and the remaining steps were skipped."; exit 1 ;;
  esac
}

delete_path() {
  local path="$1"

  if [[ "$EXECUTE" -ne 1 ]]; then
    printf 'DRY-RUN: '
    quote_cmd rm -rf "$path"
    return 0
  fi

  [[ -e "$path" ]] || return 0

  local output=""
  if ! output=$(rm -rf "$path" 2>&1); then
    if [[ "$output" == *"Operation not permitted"* ]]; then
      warn "Could not remove ${path}. Grant your terminal Full Disk Access and rerun."
    else
      warn "Could not remove ${path}: ${output}"
    fi
  fi
}

sudo_delete_path() {
  local path="$1"

  if [[ "$EXECUTE" -ne 1 ]]; then
    printf 'DRY-RUN: '
    quote_cmd sudo rm -rf "$path"
    return 0
  fi

  echo "Removing $path"
  sudo rm -rf "$path" || warn "Could not remove ${path} (even with sudo)."
}

delete_defaults_domain() {
  local domain="$1"

  if [[ "$EXECUTE" -ne 1 ]]; then
    printf 'DRY-RUN: '
    quote_cmd defaults delete "$domain"
    return 0
  fi

  local output=""
  if ! output=$(defaults delete "$domain" 2>&1); then
    if [[ "$output" == *"not found"* || "$output" == *"does not exist"* ]]; then
      return 0
    fi
    warn "Could not delete defaults domain ${domain}: ${output}"
  fi
}

reset_tcc_target() {
  local bundle_id="$1"

  if [[ "$EXECUTE" -ne 1 ]]; then
    printf 'DRY-RUN: '
    quote_cmd tccutil reset Camera "$bundle_id"
    return 0
  fi

  local output=""
  if ! output=$(tccutil reset Camera "$bundle_id" 2>&1); then
    if [[ "$output" == *'No such bundle identifier'* ]]; then
      warn "Skipping Camera TCC reset for ${bundle_id}; no installed bundle is registered."
      return 0
    fi
    warn "Camera TCC reset failed for ${bundle_id}: ${output}"
    return 0
  fi

  printf '%s\n' "$output"
}

check_sip() {
  local status=""
  status=$(csrutil status 2>/dev/null || true)
  log "System Integrity Protection status"
  printf '%s\n' "${status:-unknown}"
  if printf '%s' "$status" | grep -qi "enabled"; then
    warn "SIP is ENABLED: systemextensionsctl uninstall/reset/developer will be refused."
    warn "Disable SIP from Recovery ('csrutil disable') and reboot for a full reset."
  fi
}

show_system_extensions() {
  log "Current system extensions"
  systemextensionsctl list || true

  log "${EXT_BUNDLE_ID} copies staged under ${SYSEXT_ROOT}"
  sudo_find_staged_extensions | sed 's/^/  /' || true
}

# Print staged .systemextension bundle paths for our extension id only.
# Uses sudo because /Library/SystemExtensions is not world-readable.
sudo_find_staged_extensions() {
  [[ -d "$SYSEXT_ROOT" ]] || return 0
  if [[ "$EXECUTE" -eq 1 ]]; then
    sudo find "$SYSEXT_ROOT" -maxdepth 3 -name "${EXT_BUNDLE_ID}.systemextension" -print 2>/dev/null || true
  else
    # Best effort without elevation; may be empty if not readable.
    find "$SYSEXT_ROOT" -maxdepth 3 -name "${EXT_BUNDLE_ID}.systemextension" -print 2>/dev/null || true
  fi
}

# Print the helper's leftover driver staging directories, one per line. Only
# real directories directly in HAL_PLUGINS_DIR match: find does not follow
# symlinks, so -type d skips a symlink with a staging name, and -maxdepth 1
# keeps it out of installed bundles. The directory is world-readable, so no
# sudo is needed to list it.
find_driver_staging() {
  [[ -d "$HAL_PLUGINS_DIR" ]] || return 0
  find "$HAL_PLUGINS_DIR" -mindepth 1 -maxdepth 1 -type d \
    \( -name "${DRIVER_STAGING_PREFIX}*" -o -name "$DRIVER_LEGACY_STAGING_NAME" \) \
    -print 2>/dev/null || true
}

# Emit every LemurCam.app bundle path we can find, de-duplicated.
collect_app_bundles() {
  local candidates=()

  [[ -d "/Applications/${APP_NAME}.app" ]] && candidates+=("/Applications/${APP_NAME}.app")
  [[ -d "${HOME}/Applications/${APP_NAME}.app" ]] && candidates+=("${HOME}/Applications/${APP_NAME}.app")

  # Repo build outputs (do not descend into a matched .app).
  while IFS= read -r path; do
    [[ -n "$path" ]] && candidates+=("$path")
  done < <(find "$REPO_ROOT" -type d -name "${APP_NAME}.app" -prune -print 2>/dev/null)

  # DerivedData build products.
  local derived_root="${HOME}/Library/Developer/Xcode/DerivedData"
  if [[ -d "$derived_root" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && candidates+=("$path")
    done < <(find "$derived_root" -path "*/Build/Products/*/${APP_NAME}.app" -type d -prune -print 2>/dev/null)
  fi

  # Xcode archives. Listed so delete_apps can report them; only deleted with
  # --include-archives (see is_archived_bundle).
  if [[ -d "$ARCHIVES_ROOT" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && candidates+=("$path")
    done < <(find "$ARCHIVES_ROOT" -type d -name "${APP_NAME}.app" -prune -print 2>/dev/null)
  fi

  # Spotlight catch-all by bundle identifier (covers Downloads, Desktop, etc.).
  if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r path; do
      [[ -d "$path" && "$path" == *".app" ]] && candidates+=("$path")
    done < <(mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'" 2>/dev/null || true)
  fi

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
}

# Anchored pkill -f pattern for the extension executable, e.g.
# /Library/SystemExtensions/<UUID>/cam.lemur.app.extension.systemextension/Contents/MacOS/cam.lemur.app.extension
# Anchoring keeps it from matching unrelated commands that merely mention the
# bundle id (such as 'log stream --predicate ...'). -x is not usable here:
# process names are truncated to 16 characters.
ext_process_pattern() {
  local escaped_root="${SYSEXT_ROOT//./\\.}"
  local escaped_id="${EXT_BUNDLE_ID//./\\.}"
  printf '^%s/.*/%s$' "$escaped_root" "$escaped_id"
}

# True for an app bundle inside an Xcode archive: anything under the default
# Archives folder (including notarization Submissions copies) or inside any
# .xcarchive elsewhere (Spotlight finds those too).
is_archived_bundle() {
  local path="$1"
  [[ "$path" == "${ARCHIVES_ROOT}/"* || "$path" == *".xcarchive/"* ]]
}

stop_processes() {
  log "Stopping running LemurCam processes"
  confirm "Stop the running ${APP_NAME} app and camera extension? (sudo)"
  run_allow_fail pkill -x "$APP_NAME"
  # The extension runs as _cmiodalassistants, so killing it (and even reading
  # its command line for -f matching) needs sudo.
  sudo_run_allow_fail pkill -f "$(ext_process_pattern)"
}

uninstall_extension() {
  if [[ "$KEEP_EXTENSION" -eq 1 ]]; then
    return 0
  fi

  log "Uninstalling system extension ${EXT_BUNDLE_ID}"
  echo "Requires SIP disabled; failure here is non-fatal (staged copies are purged below)."
  confirm "Uninstall ${EXT_BUNDLE_ID} with systemextensionsctl? (sudo)"
  sudo_run_allow_fail systemextensionsctl uninstall "$TEAM_ID" "$EXT_BUNDLE_ID"
}

enable_developer_mode() {
  if [[ "$DEVELOPER_ON" -ne 1 ]]; then
    return 0
  fi

  log "Enabling system extension developer mode"
  echo "Requires SIP disabled; failure here is non-fatal."
  run_allow_fail systemextensionsctl developer on
}

delete_apps() {
  if [[ "$KEEP_APPS" -eq 1 ]]; then
    return 0
  fi

  log "Deleting LemurCam app bundles (each embeds the extension)"
  local apps=()
  local archived=()
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ "$INCLUDE_ARCHIVES" -ne 1 ]] && is_archived_bundle "$app"; then
      archived+=("$app")
    else
      apps+=("$app")
    fi
  done < <(collect_app_bundles)

  if [[ "${#archived[@]}" -gt 0 ]]; then
    printf 'Keeping app bundle(s) inside Xcode archives (pass --include-archives to delete them):\n'
    printf '  %s\n' "${archived[@]}"
    echo "macOS can still re-stage the extension from these on reboot."
  fi

  if [[ "${#apps[@]}" -eq 0 ]]; then
    if [[ "${#archived[@]}" -gt 0 ]]; then
      echo "No ${APP_NAME}.app bundles found outside Xcode archives."
    else
      echo "No ${APP_NAME}.app bundles found."
    fi
    return 0
  fi

  printf 'Found app bundle(s):\n'
  printf '  %s\n' "${apps[@]}"
  confirm "Delete these app bundle(s)?"

  local app
  for app in "${apps[@]}"; do
    delete_path "$app"
  done
}

purge_staged_extensions() {
  log "Removing staged ${EXT_BUNDLE_ID} copies under ${SYSEXT_ROOT}"
  [[ -d "$SYSEXT_ROOT" ]] || { echo "No ${SYSEXT_ROOT}."; return 0; }

  if [[ "$EXECUTE" -ne 1 ]]; then
    printf 'DRY-RUN: '
    quote_cmd sudo find "$SYSEXT_ROOT" -maxdepth 3 -name "${EXT_BUNDLE_ID}.systemextension" -exec rm -rf {} +
    local preview=""
    preview=$(sudo_find_staged_extensions)
    [[ -n "$preview" ]] && printf '%s\n' "$preview" | sed 's/^/  would remove: /'
    return 0
  fi

  confirm "Remove staged ${EXT_BUNDLE_ID} bundles under ${SYSEXT_ROOT}? (sudo)"

  local matches=""
  matches=$(sudo_find_staged_extensions)
  if [[ -z "$matches" ]]; then
    echo "No staged ${EXT_BUNDLE_ID} bundles found."
    return 0
  fi

  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    sudo_delete_path "$match"
  done <<<"$matches"
}

remove_audio_driver() {
  if [[ "$KEEP_DRIVER" -eq 1 ]]; then
    return 0
  fi

  log "Removing audio driver ${DRIVER_BUNDLE_NAME} from ${HAL_PLUGINS_DIR}"

  local found=0
  if [[ -e "$INSTALLED_DRIVER_PATH" ]]; then
    found=1
    printf '  found: %s\n' "$INSTALLED_DRIVER_PATH"
  fi

  local staging=""
  staging=$(find_driver_staging)
  if [[ -n "$staging" ]]; then
    found=1
    printf '%s\n' "$staging" | sed 's/^/  found staging: /'
  else
    echo "  no staging copies (${DRIVER_STAGING_PREFIX}*, ${DRIVER_LEGACY_STAGING_NAME})"
  fi

  # In execute mode, skip (and do not kick coreaudiod) when there is nothing to
  # remove. Dry-run always prints the commands it would run.
  if [[ "$found" -eq 0 && "$EXECUTE" -eq 1 ]]; then
    echo "No installed ${DRIVER_BUNDLE_NAME} or staging copies found."
    return 0
  fi

  confirm "Remove ${DRIVER_BUNDLE_NAME} (and any staging copies) and restart coreaudiod? (sudo)"

  sudo_delete_path "$INSTALLED_DRIVER_PATH"
  local match
  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    sudo_delete_path "$match"
  done <<<"$staging"

  # coreaudiod keeps a removed HAL plug-in loaded until it is restarted; this
  # mirrors the privileged helper's own uninstall path.
  log "Restarting coreaudiod so it drops the removed plug-in"
  sudo_run_allow_fail launchctl kickstart -k system/com.apple.audio.coreaudiod
}

reset_tcc() {
  log "Resetting Camera privacy authorization"
  if [[ "$GLOBAL_TCC_RESET" -eq 1 ]]; then
    confirm "Reset Camera privacy permission for ALL apps?"
    run tccutil reset Camera
  else
    confirm "Reset Camera privacy permission for ${APP_BUNDLE_ID} and ${EXT_BUNDLE_ID}?"
    reset_tcc_target "$APP_BUNDLE_ID"
    reset_tcc_target "$EXT_BUNDLE_ID"
  fi
}

reset_user_state() {
  if [[ "$KEEP_USER_STATE" -eq 1 ]]; then
    return 0
  fi

  log "Removing LemurCam user state"
  if [[ "$EXECUTE" -eq 1 ]]; then
    printf 'Will remove:\n'
    printf '  defaults domain %s\n' "$APP_BUNDLE_ID" "$APP_GROUP_ID"
    printf '  %s\n' \
      "${HOME}/Library/Application Support/${APP_NAME} (saved camera list)" \
      "${HOME}/Library/Containers/${APP_BUNDLE_ID}" \
      "${HOME}/Library/Group Containers/${APP_GROUP_ID}"
  fi
  confirm "Delete LemurCam settings and the saved camera list?"

  delete_defaults_domain "$APP_BUNDLE_ID"
  delete_defaults_domain "$APP_GROUP_ID"
  delete_path "${HOME}/Library/Application Support/${APP_NAME}"
  delete_path "${HOME}/Library/Containers/${APP_BUNDLE_ID}"
  delete_path "${HOME}/Library/Group Containers/${APP_GROUP_ID}"
}

reset_keychain() {
  if [[ "$KEEP_KEYCHAIN" -eq 1 ]]; then
    return 0
  fi

  log "Deleting LemurCam Keychain credentials"
  if [[ "$EXECUTE" -ne 1 ]]; then
    echo "DRY-RUN: delete all generic-password items with service ${KEYCHAIN_SERVICE}"
    return 0
  fi

  if ! security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    echo "No Keychain items found for service ${KEYCHAIN_SERVICE}."
    return 0
  fi
  confirm "Delete every Keychain item for service ${KEYCHAIN_SERVICE} (saved camera credentials)?"

  local deleted=0
  while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
    deleted=$((deleted + 1))
  done
  echo "Deleted ${deleted} Keychain item(s) for service ${KEYCHAIN_SERVICE}."
}

clean_derived_data() {
  if [[ "$KEEP_DERIVED_DATA" -eq 1 ]]; then
    return 0
  fi

  log "Deleting build outputs"
  local dirs=()
  [[ -e "$REPO_ROOT/build" ]] && dirs+=("$REPO_ROOT/build")

  local derived_root="${HOME}/Library/Developer/Xcode/DerivedData"
  if [[ -d "$derived_root" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && dirs+=("$dir")
    done < <(find "$derived_root" -maxdepth 1 -type d -name "${APP_NAME}-*" -print 2>/dev/null)
  fi

  if [[ "${#dirs[@]}" -eq 0 ]]; then
    echo "No repo build/ or ${APP_NAME} DerivedData folders found."
    return 0
  fi

  printf 'Found build output folder(s):\n'
  printf '  %s\n' "${dirs[@]}"
  confirm "Delete these build output folder(s)?"

  local dir
  for dir in "${dirs[@]}"; do
    delete_path "$dir"
  done
}

reset_system_extensions() {
  if [[ "$GLOBAL_SYSEXT_RESET" -ne 1 ]]; then
    return 0
  fi

  log "Resetting ALL system extension state"
  cat <<EOF
WARNING: 'systemextensionsctl reset' clears state for every system extension,
not just LemurCam. You may need to re-approve unrelated extensions such as VPN,
endpoint security, or other camera extensions. Requires SIP disabled.
EOF
  confirm "Run global system extension reset?"
  sudo_run_allow_fail systemextensionsctl reset
}

main() {
  if [[ "$EXECUTE" -ne 1 ]]; then
    echo "Dry-run mode. Pass --execute to make changes."
  fi

  check_sip
  show_system_extensions
  stop_processes
  uninstall_extension
  enable_developer_mode
  delete_apps
  purge_staged_extensions
  remove_audio_driver
  reset_tcc
  reset_user_state
  reset_keychain
  clean_derived_data
  reset_system_extensions

  log "Post-clean system extension state"
  systemextensionsctl list || true

  cat <<EOF

Next steps:
  1. Reboot. macOS finalizes a "waiting to uninstall on reboot" extension only
     after a restart, clears any in-memory copy, and frees the audio shm ring
     (/cam.lemur.audioring) the app shares with the driver.
  2. Bump CURRENT_PROJECT_VERSION in project.yml before rebuilding, or macOS may
     keep the old extension (the app logs "Camera extension already up to
     date (vN)" instead of "Updating camera extension: vN → vM").
  3. Rebuild and relaunch the app to re-stage a fresh extension.

If ${EXT_BUNDLE_ID} is still listed above, either a copy was missed (rerun with
the terminal granted Full Disk Access) or use --global-sysext-reset.
EOF
}

main "$@"
