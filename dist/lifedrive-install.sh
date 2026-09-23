#!/usr/bin/env bash
set -euo pipefail

RELEASE_BASE="${LIFEDRIVE_RELEASE_BASE:-https://github.com/cfa532/lifedrive-installer/releases/latest/download}"
ARCHIVE_NAME="lifedrive-bundle.tar.gz"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"
LEITHER_WORKDIR="${LIFEDRIVE_WORKDIR:-}"
UPGRADE_ONLY=0
MANAGEMENT_ONLY=0
INSTALL_LEITHER=1
LEITHER_SERVICE_ONLY=0
LEITHER_SERVICE_BOOTSTRAPPED=0
HOUSEHOLD_CONFIG=""
HOUSEHOLD_SETUP=0
setup_command_args=()
setup_arg_count=0
operation_count=0

usage() {
  cat <<'EOF'
Usage: lifedrive-install.sh [installer options] [setup options]

Installer options:
  --leither-root DIR        Select an existing node or the directory for a new Leither installation.
  --no-install-leither      Require a running Leither node; do not install or start one.
  --leither-service         Set up Leither boot startup only; do not install or change LifeDrive.
  --release-base URL        Alternate GitHub Release asset base URL.
  --upgrade                 Upgrade an existing LifeDrive without changing device authorization.
  --household              Prepare mobile household setup using the existing node address.
  --household-config FILE   Install mobile-led household setup using a private service configuration.

Setup options are forwarded to lifeDrive-setup.sh. Common examples:
  --registry-url URL
  --publisher-key FILE
  --add-device LABEL
  --identity-out FILE
  --list-devices
  --revoke-device UID
  --skip-domain
EOF
}

while (( $# )); do
  case "$1" in
    --leither-service)
      LEITHER_SERVICE_ONLY=1
      ;;
    --no-install-leither)
      INSTALL_LEITHER=0
      ;;
    --household)
      HOUSEHOLD_SETUP=1
      ;;
    --household-config)
      shift
      [[ $# -gt 0 && -f "$1" ]] || { echo "--household-config requires a configuration file" >&2; exit 2; }
      HOUSEHOLD_CONFIG="$1"
      ;;
    --leither-root)
      shift
      [[ $# -gt 0 && -n "$1" && "$1" != --* ]] || { echo "--leither-root requires a directory" >&2; exit 2; }
      LEITHER_WORKDIR="$1"
      ;;
    --release-base)
      shift
      [[ $# -gt 0 && -n "$1" && "$1" != --* ]] || { echo "--release-base requires a URL" >&2; exit 2; }
      RELEASE_BASE="${1%/}"
      ;;
    --upgrade)
      UPGRADE_ONLY=1
      operation_count=$((operation_count + 1))
      setup_command_args+=("--upgrade")
      setup_arg_count=$((setup_arg_count + 1))
      ;;
    --list-devices)
      MANAGEMENT_ONLY=1
      operation_count=$((operation_count + 1))
      setup_command_args+=("$1")
      setup_arg_count=$((setup_arg_count + 1))
      ;;
    --add-device|--revoke-device|--registry-url|--publisher-key|--identity-out)
      option="$1"
      shift
      [[ $# -gt 0 && -n "$1" && "$1" != --* ]] || { echo "$option requires a value" >&2; exit 2; }
      if [[ "$option" == --add-device || "$option" == --revoke-device ]]; then
        MANAGEMENT_ONLY=1
        operation_count=$((operation_count + 1))
      fi
      setup_command_args+=("$option" "$1")
      setup_arg_count=$((setup_arg_count + 2))
      ;;
    --skip-domain) setup_command_args+=("$1"); setup_arg_count=$((setup_arg_count + 1)) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if (( operation_count > 1 )); then
  echo "Choose only one of --upgrade, --add-device, --list-devices, or --revoke-device." >&2
  exit 2
fi
if (( LEITHER_SERVICE_ONLY )) && { (( ! INSTALL_LEITHER || operation_count || HOUSEHOLD_SETUP || setup_arg_count )) || [[ -n "$HOUSEHOLD_CONFIG" ]]; }; then
  echo "Use --leither-service with only --leither-root and installer source options." >&2
  exit 2
fi
if (( HOUSEHOLD_SETUP )) && { [[ -n "$HOUSEHOLD_CONFIG" ]] || (( MANAGEMENT_ONLY )); }; then
  echo "Use --household separately from --household-config and device-management options." >&2
  exit 2
fi

for required in node curl tar; do
  command -v "$required" >/dev/null 2>&1 || { echo "LifeDrive installation requires $required." >&2; exit 1; }
done

find_leither_pids() {
  ps -axww -o pid=,comm= 2>/dev/null | awk '
    { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "") }
    $0 == "Leither" || $0 ~ /\/Leither$/ { print pid }
  '
}

leither_version() {
  local version_json
  version_json=$(cd "$1" && ./Leither version --json) || return 1
  node -e '
    try {
      const reply = JSON.parse(process.argv[1]);
      const reported = reply?.data?.version ?? reply?.version;
      if (typeof reported !== "string") throw new Error("missing version");
      const version = reported.replace(/^V/, "");
      if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("unknown version");
      const [major, minor, patch] = version.split(".").map(Number);
      if (major === 0 && (minor < 24 || (minor === 24 && patch < 11))) throw new Error("too old");
      process.stdout.write(version);
    } catch {
      console.error("LifeDrive requires Leither V0.24.11 or newer. Upgrade Leither separately; existing nodes are never overwritten.");
      process.exit(1);
    }
  ' "$version_json"
}

install_leither_binary() (
  # Follow http://vzhan.cn/#start.html and its install.sh download layout.
  # Download only the binary and checksum; initialization stays in the final
  # private node directory, never in a temporary directory or release bundle.
  set -euo pipefail
  umask 077
  case "$(uname -s)" in Linux) leither_os=linux ;; Darwin) leither_os=darwin ;; *) echo "Unsupported Leither platform." >&2; exit 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) leither_arch=amd64 ;; arm64|aarch64) leither_arch=arm64 ;; *) echo "Unsupported Leither architecture." >&2; exit 1 ;; esac
  if command -v sha256sum >/dev/null 2>&1; then
    checksum_command=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    checksum_command=(shasum -a 256)
  else
    echo "Leither installation requires sha256sum or shasum." >&2
    exit 1
  fi
  download_dir=$(mktemp -d "${TMPDIR:-/tmp}/lifedrive-leither.XXXXXX")
  staged_binary=""
  trap 'if [[ -n "$staged_binary" ]]; then rm -f -- "$staged_binary"; fi; rm -f -- "$download_dir/versions.html" "$download_dir/Leither" "$download_dir/Leither.sha256"; rmdir -- "$download_dir"' EXIT
  base_url="http://vzhan.cn/mm/Fc1BRTFafOGzq5P8KmkVJqwS2v2"
  echo "Finding the latest Leither release from vzhan.cn..."
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 "$base_url/" -o "$download_dir/versions.html"
  latest_version=$(node -e '
const fs = require("node:fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const versions = [...html.matchAll(/href=["\x27]V(\d+\.\d+\.\d+)(?:\/|["\x27])/g)].map(match => match[1]);
versions.sort((a, b) => {
  const left = a.split(".").map(Number), right = b.split(".").map(Number);
  return left[0] - right[0] || left[1] - right[1] || left[2] - right[2];
});
if (!versions.length) { console.error("No Leither release was found in the official index."); process.exit(1); }
process.stdout.write(`V${versions[versions.length - 1]}`);
  ' "$download_dir/versions.html")
  download_url="$base_url/$latest_version/Leither.$leither_os.$leither_arch"
  echo "Downloading Leither $latest_version for $leither_os/$leither_arch..."
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 "$download_url" -o "$download_dir/Leither"
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 "$download_url.sha256" -o "$download_dir/Leither.sha256"
  expected=$(awk 'NR==1 {print $1}' "$download_dir/Leither.sha256")
  actual=$("${checksum_command[@]}" "$download_dir/Leither" | awk '{print $1}')
  if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ || "$actual" != "$expected" ]]; then
    echo "Leither SHA-256 verification failed; the binary was not installed." >&2
    exit 1
  fi
  # Install a complete binary atomically on the destination filesystem. The
  # hard link fails if another installer has already created Leither.
  staged_binary=$(mktemp "$LEITHER_WORKDIR/.Leither.XXXXXX")
  cat "$download_dir/Leither" > "$staged_binary"
  chmod 700 "$staged_binary"
  node -e 'require("node:fs").linkSync(process.argv[1], process.argv[2]);' "$staged_binary" "$LEITHER_WORKDIR/Leither"
)

leither_service_prerequisites() {
  if [[ $(id -u) == 0 ]]; then
    echo "Run setup as the account that owns the Leither node; sudo is used only to install its system service." >&2
    exit 1
  fi
  command -v sudo >/dev/null || { echo "System service setup requires sudo." >&2; exit 1; }
  case "$(uname -s)" in
    Linux)
      if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
        echo "Automatic Leither startup requires Linux with systemd. On other systems, start Leither with your service manager and use --no-install-leither." >&2
        exit 1
      fi
      systemctl show --property=Version --value >/dev/null || { echo "The systemd service manager is not reachable." >&2; exit 1; }
      ;;
    Darwin)
      command -v launchctl >/dev/null && command -v plutil >/dev/null && command -v lsof >/dev/null || { echo "macOS service setup requires launchctl, plutil, and lsof." >&2; exit 1; }
      ;;
    *) echo "Unsupported service platform." >&2; exit 1 ;;
  esac
}

leither_service_pid() {
  case "$(uname -s)" in
    Linux) systemctl show lifedrive-leither.service --property=MainPID --value 2>/dev/null ;;
    Darwin) launchctl print system/uk.inoku.leither 2>/dev/null | awk '/^[[:space:]]*pid = / {print $3}' ;;
  esac
}

leither_service_owns_process() {
  local service_pid executable process_root
  service_pid=$(leither_service_pid) || return 1
  [[ "$service_pid" =~ ^[0-9]+$ && "$service_pid" != 0 ]] || return 1
  if [[ "$(uname -s)" == Linux ]]; then
    executable=$(readlink "/proc/$service_pid/exe") || return 1
    executable="${executable% (deleted)}"
    process_root=$(readlink "/proc/$service_pid/cwd") || return 1
  else
    executable=$(ps -ww -p "$service_pid" -o comm= | sed 's/^[[:space:]]*//') || return 1
    process_root=$(lsof -a -p "$service_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || return 1
  fi
  [[ "$executable" == "$LEITHER_WORKDIR/Leither" && "$process_root" == "$LEITHER_WORKDIR" ]]
}

configure_leither_service() (
  set -euo pipefail
  umask 077
  mode="$1"
  leither_service_prerequisites
  service_os=$(uname -s)
  account=$(id -un)
  service_home=$(node -e 'process.stdout.write(require("node:os").userInfo().homedir);')
  service_work=$(mktemp -d "${TMPDIR:-/tmp}/lifedrive-leither-service.XXXXXX")
  trap 'rm -f -- "$service_work/lifedrive-leither.service" "$service_work/leither.plist"; rmdir -- "$service_work"' EXIT

  if [[ "$service_os" == Linux ]]; then
    unit="$service_work/lifedrive-leither.service"
    installed_unit=/etc/systemd/system/lifedrive-leither.service
    # Reject systemd specifiers, variable expansion, escapes and line breaks.
    # Ordinary spaces in directory names remain supported through quoting.
    case "$LEITHER_WORKDIR$service_home$account" in *$'\n'*|*$'\r'*|*'"'*|*'%'*|*'$'*|*'\'*) echo "Unsupported character in the Leither systemd service path or account." >&2; exit 1 ;; esac
    cat > "$unit" <<UNIT
[Unit]
Description=Leither node installed by LifeDrive
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=$account
WorkingDirectory="$LEITHER_WORKDIR"
Environment="HOME=$service_home"
ExecStart="$LEITHER_WORKDIR/Leither" run
UMask=0077
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
[Install]
WantedBy=multi-user.target
UNIT
    existing_unit=$(systemctl show lifedrive-leither.service --property=FragmentPath --value 2>/dev/null || true)
    dropins=$(systemctl show lifedrive-leither.service --property=DropInPaths --value 2>/dev/null || true)
    if [[ -n "$dropins" ]] ||
       { [[ -n "$existing_unit" ]] && ! cmp -s "$unit" "$existing_unit"; } ||
       { [[ -e "$installed_unit" || -L "$installed_unit" ]] && ! cmp -s "$unit" "$installed_unit"; }; then
      echo "An existing lifedrive-leither.service has a different configuration. It was not replaced." >&2
      exit 1
    fi
    if [[ "$mode" == running ]] && ! leither_service_owns_process; then
      echo "Leither is already running outside lifedrive-leither.service. Its process was left unchanged." >&2
      echo "Keep its existing service manager, or stop it during a maintenance window and rerun --leither-service --leither-root for this node." >&2
      exit 1
    fi
    if command -v systemd-analyze >/dev/null; then systemd-analyze verify "$unit"; fi
    if [[ -z "$existing_unit" ]]; then
      sudo install -o root -g root -m 644 "$unit" "$installed_unit"
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable lifedrive-leither.service
    if [[ "$mode" == stopped ]]; then sudo systemctl start lifedrive-leither.service; fi
    echo "Leither boot startup enabled: lifedrive-leither.service (user $account)."
  else
    plist="$service_work/leither.plist"
    installed_plist=/Library/LaunchDaemons/uk.inoku.leither.plist
    node - "$account" "$service_home" "$LEITHER_WORKDIR" <<'NODE' > "$plist"
const [account, home, root] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  Label: "uk.inoku.leither",
  UserName: account,
  ProgramArguments: [`${root}/Leither`, "run"],
  WorkingDirectory: root,
  EnvironmentVariables: { HOME: home, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" },
  RunAtLoad: true,
  KeepAlive: true,
  ThrottleInterval: 5,
  ExitTimeOut: 60,
  Umask: 63,
  StandardOutPath: `${root}/leither-service.log`,
  StandardErrorPath: `${root}/leither-service.log`
}));
NODE
    plutil -convert xml1 "$plist"
    plutil -lint "$plist" >/dev/null
    if [[ -e "$installed_plist" || -L "$installed_plist" ]]; then
      if ! cmp -s "$plist" "$installed_plist"; then
        echo "An existing uk.inoku.leither daemon has a different configuration. It was not replaced." >&2
        exit 1
      fi
    elif launchctl print system/uk.inoku.leither >/dev/null 2>&1; then
      echo "An unmanaged uk.inoku.leither daemon is already loaded. It was left unchanged." >&2
      exit 1
    fi
    if [[ "$mode" == running ]] && ! leither_service_owns_process; then
      echo "Leither is already running outside uk.inoku.leither. Its process was left unchanged." >&2
      echo "Keep its existing service manager, or stop it during a maintenance window and rerun --leither-service --leither-root for this node." >&2
      exit 1
    fi
    if [[ ! -e "$installed_plist" ]]; then sudo install -o root -g wheel -m 644 "$plist" "$installed_plist"; fi
    sudo launchctl enable system/uk.inoku.leither
    if [[ "$mode" == stopped ]]; then
      if launchctl print system/uk.inoku.leither >/dev/null 2>&1; then
        sudo launchctl kickstart system/uk.inoku.leither
      else
        sudo launchctl bootstrap system "$installed_plist"
      fi
    fi
    echo "Leither boot startup enabled: uk.inoku.leither (user $account)."
  fi
)

bootstrap_leither() {
  if (( ! INSTALL_LEITHER || UPGRADE_ONLY || MANAGEMENT_ONLY )); then
    echo "LifeDrive setup requires a running Leither node for this operation." >&2
    echo "Start the existing node, or run a fresh installation without --upgrade or device-management options." >&2
    exit 1
  fi
  leither_service_prerequisites
  if [[ -z "$LEITHER_WORKDIR" ]]; then
    if [[ -e ./Leither || -e ./SystemVars.json || -e ./systemvars.json || -e ./hostkey.cfg ]]; then
      LEITHER_WORKDIR="$PWD"
    elif command -v Leither >/dev/null 2>&1; then
      LEITHER_WORKDIR=$(node -e 'const fs=require("node:fs"), path=require("node:path"); process.stdout.write(path.dirname(fs.realpathSync(process.argv[1])));' "$(command -v Leither)")
    else
      [[ "${HOME:-}" == /* ]] || { echo "Set --leither-root to an absolute installation directory." >&2; exit 1; }
      LEITHER_WORKDIR="$HOME/.local/share/lifedrive/leither"
    fi
  fi
  local new_node=0 node_version node_port
  if [[ ! -e "$LEITHER_WORKDIR/Leither" && ! -L "$LEITHER_WORKDIR/Leither" ]]; then
    if [[ -d "$LEITHER_WORKDIR" && -n "$(ls -A "$LEITHER_WORKDIR")" ]]; then
      echo "Leither is missing, but $LEITHER_WORKDIR contains existing files. Choose an empty --leither-root; nothing was replaced." >&2
      exit 1
    fi
    (umask 077; mkdir -p "$LEITHER_WORKDIR")
    new_node=1
  elif [[ ! -x "$LEITHER_WORKDIR/Leither" ]]; then
    echo "Leither exists at $LEITHER_WORKDIR but is not executable. Correct its permissions and rerun setup." >&2
    exit 1
  fi
  LEITHER_WORKDIR=$(cd "$LEITHER_WORKDIR" && pwd -P)
  # Validate the selected node's port and check availability before starting it.
  # The process and HTTP version are checked again after startup.
  node_port=$(node -e '
const fs = require("node:fs"), path = require("node:path"), net = require("node:net");
try {
  const root = process.argv[1];
  let port = 4800;
  const vars = ["SystemVars.json", "systemvars.json"].map(name => path.join(root, name)).find(file => fs.existsSync(file));
  if (vars) port = JSON.parse(fs.readFileSync(vars, "utf8")).ServicePort ?? port;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid Leither ServicePort");
  const server = net.createServer();
  server.on("error", () => { console.error(`Leither port ${port} is unavailable. Free it or configure a different ServicePort in the selected node’s SystemVars.json.`); process.exitCode = 1; });
  server.listen(port, "127.0.0.1", () => server.close(() => process.stdout.write(String(port))));
} catch (error) { console.error(error.message); process.exitCode = 1; }
  ' "$LEITHER_WORKDIR") || exit 1
  if (( new_node )); then
    install_leither_binary
    echo "Initializing the new private Leither node at $LEITHER_WORKDIR..."
    (umask 077; cd "$LEITHER_WORKDIR" && ./Leither init) || { echo "Leither initialization failed; its files were retained at $LEITHER_WORKDIR." >&2; exit 1; }
    if [[ ! -s "$LEITHER_WORKDIR/SystemVars.json" || ! -s "$LEITHER_WORKDIR/hostkey.cfg" ]]; then
      echo "Leither initialization did not create its configuration and node key. Inspect $LEITHER_WORKDIR before retrying." >&2
      exit 1
    fi
  fi
  node_version=$(leither_version "$LEITHER_WORKDIR") || exit 1
  echo "Installing the Leither system service at $LEITHER_WORKDIR..."
  configure_leither_service stopped
  LEITHER_SERVICE_BOOTSTRAPPED=1
  local ready=0 attempt response
  for attempt in {1..30}; do
    response=$(curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$node_port/getvar?name=ver" 2>/dev/null || true)
    if leither_service_owns_process && node -e 'try { process.exit(JSON.parse(process.argv[1]).replace(/^V/, "") === process.argv[2] ? 0 : 1); } catch { process.exit(1); }' "$response" "$node_version"; then
      ready=1
      break
    fi
    sleep 1
  done
  if (( ! ready )); then
    echo "Leither did not become ready. Its files and service were retained." >&2
    echo "Linux: journalctl -u lifedrive-leither.service. macOS: $LEITHER_WORKDIR/leither-service.log." >&2
    exit 1
  fi
  echo "Leither V$node_version is ready on port $node_port. Continuing LifeDrive installation."
}

running_pids=$(find_leither_pids)
if [[ -z "$running_pids" ]]; then
  bootstrap_leither
  running_pids=$(find_leither_pids)
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
    leither_executable=$(ps -ww -p "$leither_pid" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
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
leither_version "$LEITHER_WORKDIR" >/dev/null || exit 1

if (( LEITHER_SERVICE_ONLY )); then
  if (( ! LEITHER_SERVICE_BOOTSTRAPPED )); then configure_leither_service running; fi
  echo "Leither system service setup is complete. LifeDrive application files were not changed."
  exit 0
fi

if [[ -s "$LEITHER_WORKDIR/lifeDrive.owner" && "$(sed -n '1p' "$LEITHER_WORKDIR/lifeDrive.owner")" != "lifedrive-key-auth-v1" ]]; then
  echo "LifeDrive installation stopped: the existing prototype uses retired password-owner state." >&2
  echo "This key-auth release intentionally requires a fresh LifeDrive owner state." >&2
  exit 1
fi
if [[ -s "$LEITHER_WORKDIR/lifeDrive.owner" && -z "$HOUSEHOLD_CONFIG" ]] && (( ! UPGRADE_ONLY && ! MANAGEMENT_ONLY )); then
  echo "LifeDrive installation stopped: an initialized LifeDrive already exists at $LEITHER_WORKDIR." >&2
  echo "Use --upgrade for application files or --add-device for another browser." >&2
  exit 1
fi

if (( UPGRADE_ONLY )); then
  if [[ ! -d "$LEITHER_WORKDIR/lifeDrive" ]] || { [[ ! -s "$LEITHER_WORKDIR/lifeDrive.owner" ]] && [[ ! -s "$LEITHER_WORKDIR/lifeDrive.households.json" ]]; }; then
    echo "LifeDrive upgrade stopped: no complete existing installation was found at $LEITHER_WORKDIR." >&2
    echo "Install it first with: npx --yes @inoku/lifedrive@latest" >&2
    exit 1
  fi
  echo "Existing LifeDrive installation found. Its device keys, address, and drive data will be preserved."
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

if (( MANAGEMENT_ONLY )); then
  export LIFEDRIVE_WORKDIR="$LEITHER_WORKDIR"
  export LIFEDRIVE_LEITHER_PATH="$LEITHER_WORKDIR/Leither"
  management_command=(/bin/bash "$INSTALL_TEMP/bundle/lifeDrive/lifeDrive-setup.sh")
  if (( setup_arg_count )); then management_command+=("${setup_command_args[@]}"); fi
  "${management_command[@]}"
  exit 0
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
# Hosted-demo assets were accidentally included in the 0.7.8 release. They
# are not used by the native app and collide with Leither's MiMei short names.
old_demo_assets="$LEITHER_WORKDIR/lifeDrive/inoku"
if [[ -d "$old_demo_assets" ]]; then rm -rf -- "$old_demo_assets"; fi
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
if [[ -d "$INSTALL_TEMP/bundle/identity" ]]; then
  mkdir -p "$LEITHER_WORKDIR/lifedrive-identity"
  for identity_asset in "$INSTALL_TEMP/bundle/identity/"*; do
    identity_name=$(basename "$identity_asset")
    cp "$identity_asset" "$LEITHER_WORKDIR/lifedrive-identity/.$identity_name.new"
    mv "$LEITHER_WORKDIR/lifedrive-identity/.$identity_name.new" "$LEITHER_WORKDIR/lifedrive-identity/$identity_name"
  done
  chmod 700 "$LEITHER_WORKDIR/lifedrive-identity"
fi
chmod 700 "$LEITHER_WORKDIR/lifeDrive"
chmod 700 "$LEITHER_WORKDIR/lifeDrive/"*.sh

export LIFEDRIVE_WORKDIR="$LEITHER_WORKDIR"
export LIFEDRIVE_LEITHER_PATH="$LEITHER_WORKDIR/Leither"
if (( HOUSEHOLD_SETUP )); then
  /bin/bash "$LEITHER_WORKDIR/lifedrive-identity/setup-node.sh" "$LEITHER_WORKDIR"
  exit 0
fi
if [[ -n "$HOUSEHOLD_CONFIG" ]]; then
  /bin/bash "$LEITHER_WORKDIR/lifedrive-identity/install.sh" "$HOUSEHOLD_CONFIG"
  exit 0
fi
if [[ -s "$LEITHER_WORKDIR/lifeDrive.households.json" ]]; then
  echo "LifeDrive application and identity-service files updated. Household users and keys were preserved."
  echo "Restart only the LifeDrive identity service through its service manager to load the new binary."
  if [[ "$(uname -s)" == Darwin && -f /Library/LaunchDaemons/uk.inoku.lifedrive-identity.plist ]]; then
    echo "macOS: sudo launchctl kickstart -k system/uk.inoku.lifedrive-identity"
  fi
  exit 0
fi
setup_command=("$LEITHER_WORKDIR/lifeDrive/lifeDrive-setup.sh")
if (( setup_arg_count )); then
  setup_command+=("${setup_command_args[@]}")
fi
"${setup_command[@]}"
