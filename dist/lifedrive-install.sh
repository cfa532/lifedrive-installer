#!/usr/bin/env bash
set -euo pipefail

RELEASE_BASE="${LIFEDRIVE_RELEASE_BASE:-https://github.com/cfa532/lifedrive-installer/releases/latest/download}"
ARCHIVE_NAME="lifedrive-bundle.tar.gz"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"
LEITHER_WORKDIR="${LIFEDRIVE_WORKDIR:-}"
UPGRADE_ONLY=0
setup_command_args=()
setup_arg_count=0

usage() {
  cat <<'EOF'
Usage: lifedrive-install.sh [installer options] [setup options]

Installer options:
  --leither-root DIR        Select one service when multiple Leither instances are running.
  --release-base URL        Alternate GitHub Release asset base URL.
  --upgrade                 Upgrade an existing LifeDrive without changing its owner or address.

Setup options are forwarded to lifeDrive-setup.sh. Common examples:
  --registry-url URL
  --publisher-key FILE
  --recover
  --skip-domain
EOF
}

while (( $# )); do
  case "$1" in
    --leither-root)
      shift
      [[ $# -gt 0 ]] || { echo "--leither-root requires a directory" >&2; exit 2; }
      LEITHER_WORKDIR="$1"
      ;;
    --release-base)
      shift
      [[ $# -gt 0 ]] || { echo "--release-base requires a URL" >&2; exit 2; }
      RELEASE_BASE="${1%/}"
      ;;
    --upgrade)
      UPGRADE_ONLY=1
      setup_command_args+=("--upgrade")
      setup_arg_count=$((setup_arg_count + 1))
      ;;
    -h|--help) usage; exit 0 ;;
    *) setup_command_args+=("$1"); setup_arg_count=$((setup_arg_count + 1)) ;;
  esac
  shift
done

running_pids=$(ps -axo pid=,comm= 2>/dev/null | awk '$2 == "Leither" || $2 ~ /\/Leither$/ { print $1 }')
if [[ -z "$running_pids" ]]; then
  echo "LifeDrive installation stopped: Leither is not running." >&2
  echo "Start the Leither service, then run this command again." >&2
  exit 1
fi

running_roots=()
while IFS= read -r leither_pid; do
  [[ "$leither_pid" =~ ^[0-9]+$ ]] || continue
  leither_executable=""
  leither_cwd=""
  if [[ -e "/proc/$leither_pid/exe" ]]; then
    leither_executable=$(readlink "/proc/$leither_pid/exe" 2>/dev/null || true)
    leither_executable="${leither_executable% (deleted)}"
  fi
  if [[ -z "$leither_executable" ]]; then
    leither_executable=$(ps -p "$leither_pid" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
  fi
  if [[ -z "$leither_executable" || "$leither_executable" != /* ]]; then
    leither_command=$(ps -p "$leither_pid" -o args= 2>/dev/null | sed -e 's/^[[:space:]]*//' || true)
    command_executable="${leither_command%% *}"
    if [[ "$command_executable" == /* ]]; then
      leither_executable="$command_executable"
    fi
  fi
  if [[ -L "/proc/$leither_pid/cwd" ]]; then
    leither_cwd=$(readlink "/proc/$leither_pid/cwd" 2>/dev/null || true)
  fi
  if [[ -z "$leither_cwd" ]] && command -v lsof >/dev/null 2>&1; then
    leither_cwd=$(lsof -a -p "$leither_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)
  fi

  discovered_root=""
  if [[ "$leither_executable" == /* && "${leither_executable##*/}" == "Leither" ]]; then
    executable_dir="${leither_executable%/*}"
    if [[ -x "$executable_dir/Leither" ]]; then
      discovered_root=$(cd "$executable_dir" && pwd -P)
    fi
  elif [[ -n "$leither_cwd" && -x "$leither_cwd/Leither" ]]; then
    discovered_root=$(cd "$leither_cwd" && pwd -P)
  fi

  if [[ -n "$discovered_root" ]]; then
    duplicate=0
    for known_root in "${running_roots[@]:-}"; do
      if [[ "$known_root" == "$discovered_root" ]]; then duplicate=1; break; fi
    done
    if (( ! duplicate )); then running_roots+=("$discovered_root"); fi
  fi
done <<< "$running_pids"

if (( ${#running_roots[@]} == 0 )); then
  echo "LifeDrive installation stopped: Leither is running, but its root directory could not be determined." >&2
  echo "Ensure the account running setup can inspect the Leither process." >&2
  exit 1
fi

if [[ -n "$LEITHER_WORKDIR" ]]; then
  if [[ ! -d "$LEITHER_WORKDIR" ]]; then
    echo "LifeDrive installation stopped: $LEITHER_WORKDIR is not a directory." >&2
    exit 1
  fi
  requested_root=$(cd "$LEITHER_WORKDIR" && pwd -P)
  root_is_running=0
  for known_root in "${running_roots[@]}"; do
    if [[ "$known_root" == "$requested_root" ]]; then root_is_running=1; break; fi
  done
  if (( ! root_is_running )); then
    echo "LifeDrive installation stopped: no running Leither service uses $requested_root." >&2
    exit 1
  fi
  LEITHER_WORKDIR="$requested_root"
elif (( ${#running_roots[@]} == 1 )); then
  LEITHER_WORKDIR="${running_roots[0]}"
else
  echo "LifeDrive installation stopped: more than one Leither service is running." >&2
  printf '  %s\n' "${running_roots[@]}" >&2
  echo "Rerun with --leither-root and one of the directories above." >&2
  exit 1
fi

if [[ ! -x "$LEITHER_WORKDIR/Leither" ]]; then
  echo "LifeDrive installation stopped: the running Leither executable is not accessible at $LEITHER_WORKDIR/Leither." >&2
  exit 1
fi
echo "Found running Leither service at $LEITHER_WORKDIR"

if (( UPGRADE_ONLY )); then
  if [[ ! -d "$LEITHER_WORKDIR/lifeDrive" || ! -s "$LEITHER_WORKDIR/lifeDrive.appid" || ! -s "$LEITHER_WORKDIR/lifeDrive.owner" ]]; then
    echo "LifeDrive upgrade stopped: no complete existing installation was found at $LEITHER_WORKDIR." >&2
    echo "Install it first with: npx --yes @inoku/lifedrive@latest" >&2
    exit 1
  fi
  echo "Existing LifeDrive installation found. Its owner, address, and drive data will be preserved."
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "LifeDrive installation requires curl." >&2
  exit 1
fi
if ! command -v tar >/dev/null 2>&1; then
  echo "LifeDrive installation requires tar." >&2
  exit 1
fi

INSTALL_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/lifedrive-install.XXXXXX")
cleanup() {
  case "$INSTALL_TEMP" in
    "${TMPDIR:-/tmp}"/lifedrive-install.*) rm -rf -- "$INSTALL_TEMP" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

if [[ "$RELEASE_BASE" == file://* ]]; then
  echo "Loading the LifeDrive release included with the npm package..."
else
  echo "Downloading the latest LifeDrive release from GitHub..."
fi
curl -fsSL --retry 3 --connect-timeout 20 -o "$INSTALL_TEMP/$ARCHIVE_NAME" "$RELEASE_BASE/$ARCHIVE_NAME"
curl -fsSL --retry 3 --connect-timeout 20 -o "$INSTALL_TEMP/$CHECKSUM_NAME" "$RELEASE_BASE/$CHECKSUM_NAME"

expected_checksum=$(awk 'NR==1 {print $1}' "$INSTALL_TEMP/$CHECKSUM_NAME")
if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum=$(sha256sum "$INSTALL_TEMP/$ARCHIVE_NAME" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum=$(shasum -a 256 "$INSTALL_TEMP/$ARCHIVE_NAME" | awk '{print $1}')
else
  echo "LifeDrive installation requires sha256sum or shasum." >&2
  exit 1
fi
if [[ ! "$expected_checksum" =~ ^[a-fA-F0-9]{64}$ || "$actual_checksum" != "$expected_checksum" ]]; then
  echo "LifeDrive release verification failed; the downloaded bundle was not installed." >&2
  exit 1
fi

mkdir -p "$INSTALL_TEMP/bundle"
tar -xzf "$INSTALL_TEMP/$ARCHIVE_NAME" -C "$INSTALL_TEMP/bundle"
if [[ ! -x "$INSTALL_TEMP/bundle/lifeDrive/lifeDrive-setup.sh" || ! -f "$INSTALL_TEMP/bundle/lifeDrive/main.go" ]]; then
  echo "LifeDrive release verification failed; required files are missing." >&2
  exit 1
fi

backup_dir="$LEITHER_WORKDIR/deploy-backups/lifedrive-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "$LEITHER_WORKDIR/lifeDrive" ]]; then
  mkdir -p "$backup_dir"
  if [[ -d "$LEITHER_WORKDIR/lifeDrive" ]]; then cp -R "$LEITHER_WORKDIR/lifeDrive" "$backup_dir/"; fi
  echo "Previous LifeDrive files backed up to $backup_dir"
fi

mkdir -p "$LEITHER_WORKDIR/lifeDrive"
# Remove the previous top-level JavaScript MApp entries before installing the
# Go dispatcher. Web assets below their hashed asset directory are retained.
old_entry_files=(
  access_check.js access_get_security_mode.js drive_get_state.js drive_list.js drive_open.js
  file_get_info.js file_read.js folder_create.js health.js object_copy.js object_move.js
  object_purge.js object_trash.js server_capabilities.js trash_list.js trash_restore.js
  upload_abort.js upload_begin.js upload_complete.js upload_write.js access_check.test.mjs
  lifeDrive-install-service.sh
)
for old_entry in "${old_entry_files[@]}"; do
  old_path="$LEITHER_WORKDIR/lifeDrive/$old_entry"
  if [[ -f "$old_path" ]]; then rm -f -- "$old_path"; fi
done
# Remove the obsolete nested web build. The Leither entry bootstrap resolves
# the current top-level browser objects below /mm/<app-mid>:<version>/.
old_web_dir="$LEITHER_WORKDIR/lifeDrive/web"
if [[ -d "$old_web_dir" ]]; then rm -rf -- "$old_web_dir"; fi
# Tahoe V0.24.05 derives the same application-entry short name, "index", from
# index.html and index_entry.js. Remove the rejected TweetWeb-era filename when
# upgrading to the distinct top-level browser object lifedrive.js.
old_browser_entry="$LEITHER_WORKDIR/lifeDrive/index_entry.js"
if [[ -f "$old_browser_entry" ]]; then rm -f -- "$old_browser_entry"; fi
# CSS is embedded in index.html. An index.css object collides with index.html
# under the same V0.24.05 short-name normalization.
old_browser_style="$LEITHER_WORKDIR/lifeDrive/index.css"
if [[ -f "$old_browser_style" ]]; then rm -f -- "$old_browser_style"; fi
cp -R "$INSTALL_TEMP/bundle/lifeDrive/." "$LEITHER_WORKDIR/lifeDrive/"
chmod 700 "$LEITHER_WORKDIR/lifeDrive"
chmod 700 "$LEITHER_WORKDIR/lifeDrive/"*.sh

export LIFEDRIVE_WORKDIR="$LEITHER_WORKDIR"
export LIFEDRIVE_LEITHER_PATH="$LEITHER_WORKDIR/Leither"
setup_command=("$LEITHER_WORKDIR/lifeDrive/lifeDrive-setup.sh")
if (( setup_arg_count )); then
  setup_command+=("${setup_command_args[@]}")
fi
"${setup_command[@]}"
