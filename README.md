# LePan / LifeDrive Installer

This public repository contains versioned LifeDrive installation assets built from the private LifeAlbum source repository.

For an ordinary Windows or macOS installation, download the matching package from the [latest release](https://github.com/cfa532/lifedrive-installer/releases/latest):

- **Windows 10/11 or Windows Server (x64):** [LePan-Setup-windows-x64.exe](https://github.com/cfa532/lifedrive-installer/releases/latest/download/LePan-Setup-windows-x64.exe)
- **Mac with Apple silicon:** [LePan-Setup-macos-arm64.pkg](https://github.com/cfa532/lifedrive-installer/releases/latest/download/LePan-Setup-macos-arm64.pkg)
- **Mac with an Intel processor:** [LePan-Setup-macos-x64.pkg](https://github.com/cfa532/lifedrive-installer/releases/latest/download/LePan-Setup-macos-x64.pkg)

The native packages contain a private Node.js runtime used only by LePan Setup. They do not install Node.js system-wide or replace an existing Node.js installation. Windows asks for Administrator approval. macOS installs **LePan Setup** in Applications, opens Terminal, and asks for an administrator password only when registering the background services. Follow the on-screen prompts to choose storage and create the first mobile invitation.

**New to LifeDrive?** Read the [user manual](USER_MANUAL.md): installing and upgrading a node, users and devices, and what to do when a device or an identity is lost.

## Command-line installation

Linux users and experienced Mac users can install Node.js 18 or later and run:

```bash
npx --yes @inoku/lifedrive
```

The npm package supports Linux and macOS on Apple Silicon/ARM64 and Intel/AMD64, plus native x64 Windows. Run it as your normal user on Linux/macOS or from an Administrator Windows Terminal on Windows. Fresh setup installs and starts Leither when it is missing. WSL, Git Bash, Homebrew, and third-party Windows service wrappers are not required. A fresh Windows node defaults to
`%ProgramData%\LifeDrive\Leither`, uses the native official x64 Leither build,
and activates household users during installation.

To upgrade an existing key-auth installation without changing its authorized devices, public address, or drive data, run:

```bash
npx --yes @inoku/lifedrive@latest --upgrade
```

The installer reuses a running Leither node and finds its directory automatically. If none is running, Linux/macOS fresh setup first looks for Leither in the selected directory, the current directory, or on `PATH`; otherwise it uses `~/.local/share/lifedrive/leither`. Windows uses `%ProgramData%\LifeDrive\Leither` unless `--leither-root` selects another directory. It downloads the matching binary from the [official Leither distribution](http://vzhan.cn/#start.html), verifies its SHA-256 checksum, initializes local configuration and keys, installs boot startup, and waits for the managed process and local version endpoint before continuing. Existing executables, configuration, and keys are never replaced.

When the installer creates a new node, it shows the free space on the selected drive and asks how many whole decimal gigabytes Leither may use. The default is **100 GB**. This is a node-wide maximum covering LePan and every other application stored by that Leither node; it does not reserve or preallocate the space. The installer refuses a value larger than the space currently available and saves the choice before Leither first starts. For unattended setup, pass `--storage-max-gb GB` or set `LIFEDRIVE_STORAGE_MAX_GB`. Existing nodes and upgrades keep their current limit; change those from LePan Settings.

Choose another empty directory for a fresh node, select a stopped node, or select among multiple running instances:

```bash
npx --yes @inoku/lifedrive --leither-root /path/to/leither
```

For example, create a fresh node with a 250 GB maximum:

```bash
npx --yes @inoku/lifedrive --leither-root /path/to/leither --storage-max-gb 250
```

Use `--no-install-leither` to require an already running node. Upgrades always require a running node and never install or start Leither. The legacy browser-device management options remain Linux/macOS-only; Windows uses household management from a paired phone. A nonempty directory without a Leither executable is left untouched. New nodes use port 4800 by default; a port conflict stops setup with instructions. Leither V0.24.11 or newer is required; older existing nodes must be upgraded separately.

### Leither starts automatically at boot

Fresh setup installs boot startup and crash recovery. Linux/macOS request `sudo`
to run Leither as the invoking account through systemd or a system
LaunchDaemon. Windows uses a SYSTEM Scheduled Task and grants that task access
to the selected node directory. Every platform sets the working directory and
runs `Leither run` in the foreground so the manager can supervise it directly.

| Platform | Service definition | Status and logs |
|---|---|---|
| Linux | `/etc/systemd/system/lifedrive-leither.service` | `systemctl status lifedrive-leither.service`; `journalctl -u lifedrive-leither.service` |
| macOS | `/Library/LaunchDaemons/uk.inoku.leither.plist` | `sudo launchctl print system/uk.inoku.leither`; `<Leither root>/leither-service.log` |
| Windows | Task Scheduler: `LifeDrive Leither` | Task Scheduler history; `Get-ScheduledTask -TaskName "LifeDrive Leither"` |

To configure only Leither's startup without changing LifeDrive files:

```bash
npx --yes @inoku/lifedrive --leither-service --leither-root /path/to/leither
```

Run this as the node's normal user, not with `sudo npx`; on Windows, use an Administrator terminal. It can enable an already running service installed by this package without restarting it. A process started manually or by another service manager is left untouched: keep that manager, or stop it in a maintenance window and disable its old boot registration before adopting the package's service. A service/task definition with different settings or another node/account is never overwritten. Normal LifeDrive upgrades do not restart Leither. Systems without systemd can supply a running node through their own manager and use `--no-install-leither`.

The npm package contains the versioned installer, checksum, and LifeDrive bundle. The Windows and macOS packages contain the same payload plus a checksum-verified Node.js 22 runtime from nodejs.org. After the package is downloaded, LifeDrive's files do not depend on GitHub's release-asset network. Installing a missing Leither runtime additionally needs access to `vzhan.cn`. Its official distribution currently uses HTTP with a same-source checksum; that checksum detects corrupt downloads and is not an authenticated signature. If npm is unavailable on Linux/macOS, use the GitHub release bootstrap directly (Node.js is still required):

```bash
curl -fLO https://github.com/cfa532/lifedrive-installer/releases/latest/download/lifedrive-install.sh
chmod +x lifedrive-install.sh
./lifedrive-install.sh
```

The bootstrap verifies `lifedrive-bundle.tar.gz` against its SHA-256 file, installs it below the detected Leither root, and runs the interactive terminal setup. The npm launcher reads those assets from its own package; the standalone bootstrap downloads them from the matching GitHub Release. All installer options after the npm package name pass through to that bootstrap.

The Linux/macOS legacy browser-owner setup uses the built-in AV1 registration endpoint and does not ask users for a service URL, AV1 login, or developer-issued code. Windows skips that shell-only flow and uses household pairing.

LifeDrive requires Leither V0.24.11 or newer. Linux/macOS browser-owner setup creates a separate Ed25519 `sodiumv2` identity for the primary browser. Windows prints a private ten-minute invitation for the first paired phone; later users and devices are managed from a paired device.

An existing installation is backed up before replacement. The explicit `--upgrade` path requires the saved application and key-auth owner state before changing files, synchronizes the same published application MID, and does not rerun device or domain setup. This release intentionally does not migrate the earlier password-owner prototype. Application files are active only after Leither advances the application from `cur` to `last`; a publication timeout leaves the prior `last` version serving users.

Source code and design documentation are maintained separately. No device key, identity bundle, PPT, publisher key, or node-specific application MID is included in these release assets.

## Household users

This release includes the household identity service for Linux, macOS, and x64 Windows. Existing installations retain their application MID. On Linux/macOS, an ordinary `--upgrade` installs the service files but does not automatically activate household mode. Fresh Windows setup uses household mode by default because the legacy browser-owner tools are shell-only.

Household activation uses the existing Leither node address. On Linux/macOS, run the matching release with `--upgrade --household`. Windows performs the same private configuration and invitation flow during fresh setup. No additional public hostname or TLS certificate is required. On iPhone or Android, use Settings → Set up users. Each user starts with an empty personal drive; older files are not imported.

On Windows, Task Scheduler entries named `LifeDrive Leither` and
`LifeDrive Identity` run as SYSTEM at startup with their working directories set
to the selected Leither root. Setup also adds a Windows Firewall rule for the
configured Leither port. The loopback identity port 4811 is not opened publicly.

On macOS, setup installs `/Library/LaunchDaemons/uk.inoku.lifedrive-identity.plist`. The identity service runs as your Leither account, starts at boot, and remains running after Terminal closes or you log out. Leither must also be running for LifeDrive to work. Logs are stored in `<Leither root>/.lifedrive-household/identity.log`. Stop any previously started foreground identity service before activating the daemon. The advanced `--household-config` option continues to print a manual start command for custom configurations.

The shared browser URL remains `http://drive.lepan.org/?n=<node-id>`. Native identities persist; a paired browser stays signed in until it goes seven days without use. Direct setup requires Leither to enforce private MiMei access and stops if its checks cannot confirm that. See the source deployment notes for the HTTP transport limitations.

Once synchronized, Leither follows new publications of the same application MID. The household browser also loads that published application. Updates to the separate identity-service executable require another npm upgrade; the Windows upgrader restarts only its identity task, while Linux/macOS operators restart their identity service. The installer never restarts Leither. Install mobile application updates separately.

After upgrading on macOS, restart only the identity service:

```bash
sudo launchctl kickstart -k system/uk.inoku.lifedrive-identity
sudo launchctl print system/uk.inoku.lifedrive-identity
curl --fail http://127.0.0.1:4811/health
```

## iPhone photo backup with your own domain

The photo HTTPS helper supports a domain controlled by the node owner. Use a
release whose `lifedrive-identity/setup-photo-https.sh --help` lists `--domain`.
Automatic certificate management is built into the identity service on Linux
and macOS; nginx, Certbot and DNS-provider credentials are not required. It is
separate from ordinary household pairing and backup.

Create a dedicated A record, such as `photos.example.com`, pointing to the node's
public IPv4 address. Any DNS provider is supported; on Cloudflare use **DNS only**.
Public TCP port 443 must reach the identity service's private photo listener.
The default router mapping is WAN 443 → node 8443. Port 80 is not needed.
Carrier-grade NAT requires a separately configured reachable endpoint or
TLS pass-through tunnel; creating DNS does not provide connectivity.

Wait until at least one iPhone is paired with the node and its owner intends to
enable photo sync before creating this record. Node installation and pairing do
not enable iOS background photo upload. The app registers it only after explicit
Photos consent and a successful HTTPS readiness response from the paired node.

From the installed node's `lifedrive-identity` directory, run:

```bash
bash setup-photo-https.sh --domain photos.example.com --agree-acme-terms
```

On Windows, open an Administrator PowerShell in that directory and run:

```powershell
.\setup-photo-https.ps1 -Domain photos.example.com -AgreeAcmeTerms
```

The Windows helper opens only the private photo-listener port (8443 by default)
in Windows Firewall. The router must still forward public TCP 443 to that private
port. The ordinary Leither port remains separately forwarded; port 4811 and
public port 80 are not needed.

Replace the example hostname with yours and run the command as the Leither
account. This accepts Let's Encrypt's subscriber agreement, obtains a certificate
through TLS-ALPN-01 and enables automatic renewal. Use
`--photo-listen ADDRESS:PORT` only to change the default private listener. It restarts only
LifeDrive identity and verifies the trusted HTTPS endpoint. Leither is not
restarted. The ACME account and certificates stay in the private identity state;
none is included in the installer package.

The iPhone needs a LePan build containing the Photos background-upload extension
and iOS 26.5 or later. Open **Settings → Auto sync**, enable Photos with **Full
Access**, and check the photo-change backup status below **Wi-Fi only**. Paired
phones discover the address from their node; no address needs to be entered on
each phone. iOS decides when uploads run. File and Android backup use their
existing connection.

To change domains, finish pending uploads, point the new name at the node and
rerun the helper with that name. Reopen LePan on each phone after setup. The old
photo hostname is no longer served after successful activation; jobs already
queued to that address may require retries. The helper restores the previous
identity configuration if activation fails. Old DNS records and private ACME
cache entries are not deleted automatically.
